import Darwin
import Foundation

/// The host side of a simulator-retrofitting wire protocol: a Unix-domain
/// socket server speaking newline-delimited JSON to a single simulator client.
///
/// This class owns everything the products used to duplicate — socket
/// lifecycle, NDJSON framing, the `hello` handshake, last-connection-wins
/// takeover, hardened client sockets, and the socket-ownership guard. Domain
/// behavior stays with the product: every decoded message except `hello` is
/// handed to `onMessage`, and replies go out through `send(_:)`.
///
/// All socket I/O and every handler callback run on the private serial
/// `ioQueue`; published properties are updated on the main thread.
public final class ProtocolServer: ObservableObject {
    public enum Status: Equatable, Sendable {
        case stopped
        case listening
        case clientConnected
        /// Another live provider already owns the socket path. This server
        /// refuses to steal it — see the ownership guard in `start()`.
        case blocked(String)
    }

    public enum TeardownReason: Sendable {
        /// The client went away (closed, crashed, or stopped reading).
        case disconnected
        /// A newer client took over the slot.
        case superseded
        /// The server itself is shutting down.
        case stopped
    }

    @Published public private(set) var status: Status = .stopped
    @Published public private(set) var connectedClient: SocketClientInfo?
    @Published public private(set) var lastActivity: String = ""
    @Published public private(set) var trafficActive: Bool = false

    /// Every decoded message except `hello`, on the I/O queue.
    public var onMessage: (([String: Any]) -> Void)?
    /// A client connected (before its first message), on the I/O queue.
    public var onClientConnected: ((SocketClientInfo?) -> Void)?
    /// The current client's domain state must be dropped, on the I/O queue.
    /// Fired for disconnects, takeover eviction, and server stop alike.
    public var onClientTeardown: ((TeardownReason) -> Void)?

    public var isRunning: Bool { status != .stopped }

    private let socketPath: String
    private let name: String
    private let appVersion: String?
    private let ioQueue: DispatchQueue
    private static let ioQueueKey = DispatchSpecificKey<UInt8>()

    // Guarded by ioQueue
    private var serverFd: Int32 = -1
    private var clientFd: Int32 = -1
    private var clientInfo: SocketClientInfo?
    private var clientGeneration: UInt64 = 0
    private var acceptSource: DispatchSourceRead?
    private var readSource: DispatchSourceRead?
    private var readBuffer = Data()

    /// - Parameters:
    ///   - socketPath: the Unix-domain socket this provider serves.
    ///   - name: log prefix and display name, e.g. `"ImpossiBLE-Mock"`.
    ///   - appVersion: the provider's marketing version; a client `hello`
    ///     reporting a different library version is logged as skew.
    public init(socketPath: String, name: String, appVersion: String? = nil) {
        self.socketPath = socketPath
        self.name = name
        self.appVersion = appVersion
        self.ioQueue = DispatchQueue(label: "simbridge.server.io.\(name)")
        self.ioQueue.setSpecific(key: Self.ioQueueKey, value: 1)
        // Belt and braces next to the per-fd SO_NOSIGPIPE: a write that races a
        // client teardown must return an error, not kill the whole provider.
        signal(SIGPIPE, SIG_IGN)
    }

    // MARK: - Lifecycle

    public func start(completion: (() -> Void)? = nil) {
        ioQueue.async { [self] in
            defer {
                if let completion {
                    DispatchQueue.main.async(execute: completion)
                }
            }
            guard serverFd < 0 else { return }

            // Ownership guard: never steal the socket from a live provider
            // (another copy of this app, or the suite app). Only a stale file
            // nobody answers on is unlinked.
            if access(socketPath, F_OK) == 0, Self.probeListener(at: socketPath) {
                let message = "Another provider is already serving \(socketPath)"
                NSLog("%@: %@ — refusing to start", name, message)
                publishStatus(.blocked(message))
                log(message)
                return
            }

            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else {
                NSLog("%@: socket() failed", name)
                return
            }

            unlink(socketPath)

            guard Self.bind(fd: fd, to: socketPath) else {
                NSLog("%@: bind() failed: %d", name, errno)
                close(fd)
                return
            }

            guard listen(fd, 2) == 0 else {
                NSLog("%@: listen() failed", name)
                close(fd)
                return
            }

            serverFd = fd
            publishStatus(.listening)
            log("Listening")

            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: ioQueue)
            source.setEventHandler { [weak self] in
                self?.acceptClient()
            }
            source.setCancelHandler {
                close(fd)
            }
            source.resume()
            acceptSource = source
        }
    }

    public func stop(completion: (() -> Void)? = nil) {
        ioQueue.async { [self] in
            let hadServer = serverFd >= 0

            readSource?.cancel()
            readSource = nil
            if clientFd >= 0 {
                close(clientFd)
                clientFd = -1
            }
            clientInfo = nil
            publishConnectedClient(nil)
            clientGeneration &+= 1

            acceptSource?.cancel()
            acceptSource = nil
            serverFd = -1

            if hadServer {
                unlink(socketPath)
            }

            readBuffer.removeAll()
            onClientTeardown?(.stopped)

            publishStatus(.stopped)
            log("Stopped")

            if let completion {
                DispatchQueue.main.async(execute: completion)
            }
        }
    }

    /// Run work on the I/O queue, serialized with message handling. Lets the
    /// domain layer guard its own state by this queue during migration.
    public func performOnIOQueue(_ work: @escaping () -> Void) {
        ioQueue.async(execute: work)
    }

    /// Surface a domain-layer event in `lastActivity` (with the traffic pulse),
    /// e.g. "Session 3 started" or "Auto-paired". Callable from any queue.
    public func note(_ message: String) {
        log(message)
    }

    public func terminateConnectedClient() {
        ioQueue.async { [self] in
            guard let pid = clientInfo?.pid, pid > 0 else { return }
            if Darwin.kill(pid, SIGTERM) == 0 {
                log("Terminating client pid=\(pid)")
            } else {
                log("Failed to terminate client pid=\(pid): errno \(errno)")
            }
        }
    }

    // MARK: - Connection (ioQueue)

    private func acceptClient() {
        let fd = accept(serverFd, nil, nil)
        guard fd >= 0 else { return }

        configureClientSocket(fd)

        // Last-connection-wins: the freshly launched simulator app takes over.
        // The previous client is told it was superseded (its library then stops
        // auto-reconnecting) and its domain state is torn down — otherwise the
        // new client would inherit live state it never asked for.
        if clientFd >= 0 {
            let newcomer = peerClientInfo(for: fd)
            sendConnectionRejected(to: clientFd, supersededBy: newcomer)
            readSource?.cancel()
            readSource = nil
            close(clientFd)
            clientFd = -1
            let suffix = clientInfo?.messageSuffix ?? "pid=0, process=unknown"
            clientInfo = nil
            publishConnectedClient(nil)
            onClientTeardown?(.superseded)
            log("Client superseded (\(suffix))")
        }

        clientFd = fd
        clientInfo = peerClientInfo(for: fd)
        publishConnectedClient(clientInfo)
        clientGeneration &+= 1
        let generation = clientGeneration
        readBuffer.removeAll()

        publishStatus(.clientConnected)
        let suffix = clientInfo?.messageSuffix ?? "pid=0, process=unknown"
        log("Client connected \(suffix)")
        onClientConnected?(clientInfo)

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: ioQueue)
        source.setEventHandler { [weak self] in
            self?.readFromClient(fd: fd, generation: generation)
        }
        source.setCancelHandler { }
        source.resume()
        readSource = source
    }

    private func readFromClient(fd: Int32, generation: UInt64) {
        var buf = [UInt8](repeating: 0, count: 4096)
        let n = read(fd, &buf, buf.count)
        if n <= 0 {
            guard generation == clientGeneration else { return }
            handleClientDisconnect(fd: fd, reason: "Client disconnected")
            return
        }
        readBuffer.append(contentsOf: buf[0..<n])

        while let newlineIndex = readBuffer.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = readBuffer[readBuffer.startIndex..<newlineIndex]
            readBuffer.removeSubrange(readBuffer.startIndex...newlineIndex)
            if lineData.isEmpty { continue }
            guard let msg = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let type = msg["type"] as? String
            else { continue }

            log("recv: \(type)")
            if type == "hello" {
                handleHello(msg)
            } else {
                onMessage?(msg)
            }
        }
    }

    /// Tear down the current client connection. Safe to call from the read
    /// path and from a failed write alike; stale fds are ignored.
    private func handleClientDisconnect(fd: Int32, reason: String) {
        guard fd == clientFd else { return }
        readSource?.cancel()
        readSource = nil
        close(fd)
        clientFd = -1
        clientInfo = nil
        publishConnectedClient(nil)
        readBuffer.removeAll()
        onClientTeardown?(.disconnected)
        publishStatus(serverFd >= 0 ? .listening : .stopped)
        log(reason)
    }

    // MARK: - Hello

    private func handleHello(_ msg: [String: Any]) {
        let version = msg["clientVersion"] as? String
        let bundleId = msg["bundleId"] as? String
        var info = clientInfo ?? SocketClientInfo(
            pid: pid_t((msg["pid"] as? NSNumber)?.int32Value ?? 0),
            processName: bundleId ?? "unknown"
        )
        info.libraryVersion = version
        info.bundleId = bundleId
        clientInfo = info
        publishConnectedClient(info)
        if let version, let appVersion, version != appVersion {
            NSLog("%@: client library %@ does not match app %@ — pin them together", name, version, appVersion)
        }
        log("Client hello — library \(version ?? "unknown") (\(bundleId ?? "?"))")
    }

    // MARK: - Send

    /// Send one protocol message to the connected client. Callable from any
    /// queue; executed on the I/O queue (directly when already on it, so
    /// replies from `onMessage` keep their ordering).
    public func send(_ msg: [String: Any]) {
        if DispatchQueue.getSpecific(key: Self.ioQueueKey) != nil {
            sendLocked(msg)
        } else {
            ioQueue.async { [self] in
                sendLocked(msg)
            }
        }
    }

    private func sendLocked(_ msg: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: msg),
              clientFd >= 0 else { return }
        var payload = data
        payload.append(UInt8(ascii: "\n"))
        let fd = clientFd
        guard write(payload, to: fd) else {
            handleClientDisconnect(fd: fd, reason: "Client stopped reading; disconnected")
            return
        }
    }

    /// Sent to the *previous* client when a new connection takes over. The
    /// code stays "clientBusy" so older libraries handle eviction identically.
    private func sendConnectionRejected(to fd: Int32, supersededBy newcomer: SocketClientInfo?) {
        let suffix = newcomer?.messageSuffix ?? "pid=0, process=unknown"
        let msg: [String: Any] = [
            "type": "connectionRejected",
            "code": "clientBusy",
            "message": "superseded by a newer client (\(suffix))",
            "activeClient": newcomer?.wireValue ?? [
                "pid": 0,
                "processName": "unknown",
            ],
            "retry": false,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: msg) else { return }
        var payload = data
        payload.append(UInt8(ascii: "\n"))
        // Best effort: the fd is closed right after, a failed write is fine.
        _ = write(payload, to: fd)
    }

    private func write(_ payload: Data, to fd: Int32) -> Bool {
        payload.withUnsafeBytes { ptr in
            guard let base = ptr.baseAddress else { return false }
            var written = 0
            while written < payload.count {
                let n = Darwin.write(fd, base.advanced(by: written), payload.count - written)
                if n <= 0 { return false }
                written += n
            }
            return true
        }
    }

    // MARK: - Socket plumbing

    /// Drops the client fd on both socket options: without SO_NOSIGPIPE a write
    /// racing a client teardown kills the process, and without a send timeout a
    /// client that stops reading (a suspended simulator app) fills the send
    /// buffer and wedges the I/O queue in a blocking write() — taking the whole
    /// provider down with it, since everything runs through this queue.
    private func configureClientSocket(_ fd: Int32) {
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var sendBufferSize: Int32 = 256 * 1024
        setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &sendBufferSize, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    private func peerClientInfo(for fd: Int32) -> SocketClientInfo? {
        var pid = pid_t(0)
        var len = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &len) == 0, pid > 0 else {
            return nil
        }

        var nameBuffer = [CChar](repeating: 0, count: 4096)
        let result = proc_name(pid, &nameBuffer, UInt32(nameBuffer.count))
        let processName = result > 0 ? String(cString: nameBuffer) : "unknown"
        return SocketClientInfo(pid: pid, processName: processName)
    }

    private static func bind(fd: Int32, to path: String) -> Bool {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = path.utf8CString
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            let raw = UnsafeMutableRawPointer(ptr)
            pathBytes.withUnsafeBufferPointer { buf in
                raw.copyMemory(from: buf.baseAddress!, byteCount: min(buf.count, 104))
            }
        }
        return withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        } == 0
    }

    /// True when a live listener answers on the socket path. A stale file left
    /// by a crashed provider refuses the connection and may be unlinked.
    private static func probeListener(at path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = path.utf8CString
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            let raw = UnsafeMutableRawPointer(ptr)
            pathBytes.withUnsafeBufferPointer { buf in
                raw.copyMemory(from: buf.baseAddress!, byteCount: min(buf.count, 104))
            }
        }
        return withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        } == 0
    }

    // MARK: - Publishing

    private func publishStatus(_ newStatus: Status) {
        DispatchQueue.main.async { [weak self] in
            self?.status = newStatus
        }
    }

    private func publishConnectedClient(_ client: SocketClientInfo?) {
        DispatchQueue.main.async { [weak self] in
            self?.connectedClient = client
        }
    }

    private var pulseWorkItem: DispatchWorkItem?

    /// Updates `lastActivity` and pulses `trafficActive` for the UI. Note that
    /// this intentionally does not write to the system log — absence of console
    /// output is not evidence that something failed.
    private func log(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lastActivity = message
            self.pulseTraffic()
        }
    }

    private func pulseTraffic() {
        pulseWorkItem?.cancel()
        trafficActive = true
        let item = DispatchWorkItem { [weak self] in
            self?.trafficActive = false
        }
        pulseWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
    }
}
