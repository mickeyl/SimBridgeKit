import Foundation

/// The three-way provider selection every retrofitting product shares.
public enum ProviderMode: String, CaseIterable, Identifiable, Sendable {
    case off
    case mock
    case passthrough

    public var id: String { rawValue }

    public var title: String {
        switch self {
            case .off: "Off"
            case .mock: "Mock"
            case .passthrough: "Passthrough"
        }
    }

    public static let defaultsKey = "SelectedProviderMode"

    /// - Parameter legacyServerEnabledKey: pre-mode-picker installs persisted a
    ///   plain on/off flag; pass its key to map `true` to `.mock`.
    public static func persisted(key: String = defaultsKey, legacyServerEnabledKey: String? = nil) -> ProviderMode {
        if let rawValue = UserDefaults.standard.string(forKey: key),
           let mode = ProviderMode(rawValue: rawValue) {
            return mode
        }
        if let legacyServerEnabledKey, UserDefaults.standard.bool(forKey: legacyServerEnabledKey) {
            return .mock
        }
        return .off
    }

    public func persist(key: String = Self.defaultsKey) {
        UserDefaults.standard.set(rawValue, forKey: key)
    }
}
