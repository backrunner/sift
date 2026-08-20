import Foundation

/// A shared, persistent flag read by both the app and the message-filter extension.
public enum DeveloperModeStore {
    static let enabledKey = "Sift.developerModeEnabled.v1"

    public static func isEnabled(defaults: UserDefaults? = nil) -> Bool {
        (defaults ?? ModelSelectionStore.sharedDefaults()).bool(forKey: enabledKey)
    }

    @discardableResult
    public static func enable(defaults: UserDefaults? = nil) -> Bool {
        let store = defaults ?? ModelSelectionStore.sharedDefaults()
        let wasEnabled = store.bool(forKey: enabledKey)
        store.set(true, forKey: enabledKey)
        return !wasEnabled
    }
}
