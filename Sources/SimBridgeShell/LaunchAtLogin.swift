import AppKit
import Foundation

/// Launch-at-login via a LaunchAgent plist. The state lives in the filesystem,
/// not in UserDefaults — mirror it in view state for immediate toggle feedback.
public struct LaunchAtLogin {
    private let label: String
    private let agentPath: String

    /// - Parameter label: the LaunchAgent label, conventionally the bundle id.
    public init(label: String) {
        self.label = label
        self.agentPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
            .path
    }

    public var isEnabled: Bool {
        FileManager.default.fileExists(atPath: agentPath)
    }

    public func setEnabled(_ enabled: Bool) {
        if enabled {
            writeAgent()
        } else {
            try? FileManager.default.removeItem(atPath: agentPath)
        }
    }

    private func writeAgent() {
        let bundleURL = Bundle.main.bundleURL
        let arguments: [String] = if bundleURL.pathExtension == "app" {
            ["/usr/bin/open", bundleURL.path]
        } else {
            [Bundle.main.executableURL?.path ?? ProcessInfo.processInfo.arguments[0]]
        }
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": arguments,
            "RunAtLoad": true,
        ]
        let dir = (agentPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) {
            FileManager.default.createFile(atPath: agentPath, contents: data)
        }
    }
}
