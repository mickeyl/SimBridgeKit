import Foundation

public enum ShellPreferences {
    public static let dismissControlWindowOnDeactivateKey = "DismissControlWindowOnDeactivate"
    public static let controlWindowBehaviorDidChange = Notification.Name("SimBridgeShell.controlWindowBehaviorDidChange")

    public static var dismissControlWindowOnDeactivate: Bool {
        get { UserDefaults.standard.bool(forKey: dismissControlWindowOnDeactivateKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: dismissControlWindowOnDeactivateKey)
            NotificationCenter.default.post(name: controlWindowBehaviorDidChange, object: nil)
        }
    }
}
