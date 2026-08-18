import Foundation

/// Identity of the simulator app connected to a provider socket.
///
/// The pid and process name come from the socket peer at accept time;
/// `libraryVersion` and `bundleId` arrive with the client's `hello` message
/// and stay nil for libraries that predate the handshake.
public struct SocketClientInfo: Equatable, Sendable {
    public let pid: pid_t
    public let processName: String
    public var libraryVersion: String?
    public var bundleId: String?

    public init(pid: pid_t, processName: String, libraryVersion: String? = nil, bundleId: String? = nil) {
        self.pid = pid
        self.processName = processName
        self.libraryVersion = libraryVersion
        self.bundleId = bundleId
    }

    public var displayText: String {
        "\(processName) (PID \(pid))"
    }

    public var messageSuffix: String {
        "pid=\(pid), process=\(processName)"
    }

    public var wireValue: [String: Any] {
        [
            "pid": Int(pid),
            "processName": processName,
        ]
    }
}
