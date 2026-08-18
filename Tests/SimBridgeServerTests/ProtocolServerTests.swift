import Darwin
import XCTest
@testable import SimBridgeServer

/// A minimal blocking NDJSON client for exercising the server over a real
/// Unix-domain socket.
private final class TestClient {
    private(set) var fd: Int32
    private var buffer = Data()
    private(set) var sawEOF = false

    init?(path: String) {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = path.utf8CString
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            let raw = UnsafeMutableRawPointer(ptr)
            pathBytes.withUnsafeBufferPointer { buf in
                raw.copyMemory(from: buf.baseAddress!, byteCount: min(buf.count, 104))
            }
        }
        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            close(fd)
            return nil
        }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    func send(_ msg: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: msg) else { return }
        data.append(UInt8(ascii: "\n"))
        _ = data.withUnsafeBytes { ptr in
            write(fd, ptr.baseAddress, ptr.count)
        }
    }

    /// Collects messages until the deadline passes or EOF is seen.
    func readMessages(for duration: TimeInterval) -> [[String: Any]] {
        var messages: [[String: Any]] = []
        let deadline = Date().addingTimeInterval(duration)
        while Date() < deadline, !sawEOF {
            var timeout = timeval(tv_sec: 0, tv_usec: 200_000)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var chunk = [UInt8](repeating: 0, count: 4096)
            let n = read(fd, &chunk, chunk.count)
            if n == 0 {
                sawEOF = true
                break
            }
            if n < 0 {
                continue
            }
            buffer.append(contentsOf: chunk[0..<n])
            while let newlineIndex = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = buffer[buffer.startIndex..<newlineIndex]
                buffer.removeSubrange(buffer.startIndex...newlineIndex)
                if line.isEmpty { continue }
                if let msg = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                    messages.append(msg)
                }
            }
        }
        return messages
    }

    /// Close with an RST so the peer's next write fails immediately.
    func closeWithReset() {
        var linger = Darwin.linger(l_onoff: 1, l_linger: 0)
        setsockopt(fd, SOL_SOCKET, SO_LINGER, &linger, socklen_t(MemoryLayout<Darwin.linger>.size))
        close(fd)
        fd = -1
    }

    func shutdown() {
        if fd >= 0 {
            close(fd)
            fd = -1
        }
    }
}

final class ProtocolServerTests: XCTestCase {
    private var socketPath = ""
    private var server: ProtocolServer!

    override func setUp() {
        super.setUp()
        socketPath = "/tmp/sbk-test-\(UUID().uuidString.prefix(8)).sock"
        server = ProtocolServer(socketPath: socketPath, name: "SBK-Test", appVersion: "1.0.0")
    }

    override func tearDown() {
        let stopped = expectation(description: "stopped")
        server.stop { stopped.fulfill() }
        wait(for: [stopped], timeout: 2)
        server = nil
        unlink(socketPath)
        super.tearDown()
    }

    private func startServer(_ server: ProtocolServer? = nil) {
        let started = expectation(description: "started")
        (server ?? self.server).start { started.fulfill() }
        wait(for: [started], timeout: 2)
    }

    func testHelloPopulatesClientInfoAndIsNotForwarded() {
        var forwarded: [String] = []
        server.onMessage = { msg in
            forwarded.append(msg["type"] as? String ?? "?")
        }
        startServer()

        let client = TestClient(path: socketPath)
        XCTAssertNotNil(client)
        client?.send(["type": "hello", "clientVersion": "1.0.0", "bundleId": "test.bundle", "pid": 1234])
        client?.send(["type": "ping"])

        let expectation = expectation(description: "client info published")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { expectation.fulfill() }
        wait(for: [expectation], timeout: 2)

        XCTAssertEqual(server.connectedClient?.libraryVersion, "1.0.0")
        XCTAssertEqual(server.connectedClient?.bundleId, "test.bundle")
        XCTAssertEqual(forwarded, ["ping"], "hello must be consumed by the server, everything else forwarded")
        client?.shutdown()
    }

    func testSendRepliesReachTheClient() {
        server.onMessage = { [weak server] msg in
            guard msg["type"] as? String == "echo" else { return }
            server?.send(["type": "echoReply", "payload": msg["payload"] as? String ?? ""])
        }
        startServer()

        let client = TestClient(path: socketPath)
        client?.send(["type": "echo", "payload": "hi"])
        let messages = client?.readMessages(for: 1.0) ?? []

        XCTAssertEqual(messages.first?["type"] as? String, "echoReply")
        XCTAssertEqual(messages.first?["payload"] as? String, "hi")
        client?.shutdown()
    }

    func testTakeoverEvictsPreviousClient() {
        var teardowns: [ProtocolServer.TeardownReason] = []
        server.onClientTeardown = { teardowns.append($0) }
        startServer()

        let first = TestClient(path: socketPath)
        first?.send(["type": "hello", "clientVersion": "1.0.0", "bundleId": "first", "pid": 1])
        _ = first?.readMessages(for: 0.3)

        let second = TestClient(path: socketPath)
        second?.send(["type": "hello", "clientVersion": "1.0.0", "bundleId": "second", "pid": 2])

        let firstMessages = first?.readMessages(for: 1.5) ?? []
        let rejection = firstMessages.first { $0["type"] as? String == "connectionRejected" }
        XCTAssertNotNil(rejection, "the previous client must be told it was superseded")
        XCTAssertEqual(rejection?["code"] as? String, "clientBusy")
        XCTAssertEqual(rejection?["retry"] as? Bool, false)
        XCTAssertEqual(first?.sawEOF, true, "the previous client's connection must be closed")
        XCTAssertTrue(teardowns.contains(.superseded))

        // The newcomer is served.
        server.onMessage = { [weak server] msg in
            guard msg["type"] as? String == "ping" else { return }
            server?.send(["type": "pong"])
        }
        second?.send(["type": "ping"])
        let secondMessages = second?.readMessages(for: 1.0) ?? []
        XCTAssertTrue(secondMessages.contains { $0["type"] as? String == "pong" })
        XCTAssertEqual(second?.sawEOF, false)

        first?.shutdown()
        second?.shutdown()
    }

    func testOwnershipGuardBlocksSecondServer() {
        startServer()

        let contender = ProtocolServer(socketPath: socketPath, name: "SBK-Contender")
        startServer(contender)

        let settled = expectation(description: "status settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { settled.fulfill() }
        wait(for: [settled], timeout: 2)

        guard case .blocked = contender.status else {
            XCTFail("second server must refuse to steal a live socket, got \(contender.status)")
            return
        }

        // The original server still accepts clients.
        let client = TestClient(path: socketPath)
        XCTAssertNotNil(client)
        client?.shutdown()
    }

    func testStaleSocketFileIsReclaimed() {
        // A crashed provider leaves a socket file nobody listens on.
        let staleFd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            let raw = UnsafeMutableRawPointer(ptr)
            pathBytes.withUnsafeBufferPointer { buf in
                raw.copyMemory(from: buf.baseAddress!, byteCount: min(buf.count, 104))
            }
        }
        _ = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(staleFd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        close(staleFd)
        XCTAssertEqual(access(socketPath, F_OK), 0, "stale socket file exists")

        startServer()

        let client = TestClient(path: socketPath)
        XCTAssertNotNil(client, "server must reclaim a stale socket file")
        client?.shutdown()
    }

    func testPeerDeathWithResetDisconnectsInsteadOfKilling() {
        server.onMessage = { [weak server] msg in
            guard msg["type"] as? String == "flood" else { return }
            for i in 0..<50 {
                server?.send(["type": "burst", "index": i])
            }
        }
        startServer()

        let client = TestClient(path: socketPath)
        client?.send(["type": "flood"])
        _ = client?.readMessages(for: 0.3)
        client?.closeWithReset()

        // Trigger writes against the dead peer; the server must survive and
        // accept a fresh client afterwards.
        Thread.sleep(forTimeInterval: 0.2)
        server.send(["type": "burst", "index": -1])
        Thread.sleep(forTimeInterval: 0.2)

        let next = TestClient(path: socketPath)
        XCTAssertNotNil(next)
        server.onMessage = { [weak server] msg in
            guard msg["type"] as? String == "ping" else { return }
            server?.send(["type": "pong"])
        }
        next?.send(["type": "ping"])
        let messages = next?.readMessages(for: 1.0) ?? []
        XCTAssertTrue(messages.contains { $0["type"] as? String == "pong" })
        next?.shutdown()
    }
}
