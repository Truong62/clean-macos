import Foundation

/// Central UserDefaults keys + typed accessors for clipboard settings.
/// `SettingsView` writes these via @AppStorage using the same string keys.
enum ClipboardSettings {
    static let persistKey = "clipboardPersist"
    static let maxItemsKey = "clipboardMaxItems"
    static let skipConcealedKey = "clipboardSkipConcealed"

    static let defaultMaxItems = 200

    /// Default true (history survives quit) when the key was never set.
    static var persist: Bool {
        UserDefaults.standard.object(forKey: persistKey) as? Bool ?? true
    }

    static var maxItems: Int {
        let v = UserDefaults.standard.integer(forKey: maxItemsKey)
        return v > 0 ? v : defaultMaxItems
    }

    /// Default false (store everything) when the key was never set.
    static var skipConcealed: Bool {
        UserDefaults.standard.bool(forKey: skipConcealedKey)
    }
}
