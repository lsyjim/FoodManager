import Foundation

extension Notification.Name {
    /// Favorite categories / foods changed on another device.
    static let favoritesDidChangeExternally = Notification.Name("FavoritesDidChangeExternally")
}

/// iCloud key-value storage, behind a protocol so tests use a fake.
protocol KeyValueCloudStore: AnyObject {
    func object(forKey key: String) -> Any?
    func set(_ value: Any?, forKey key: String)
    @discardableResult func synchronize() -> Bool
}

/// The system methods already match the protocol (`set(_:forKey:)` accepts nil to remove).
extension NSUbiquitousKeyValueStore: KeyValueCloudStore {}

/// Mirrors favorite categories and favorite foods (small preferences) through iCloud key-value storage. The local
/// UserDefaults keys stay the source the app reads, so everything works offline. Device-specific settings —
/// notification preferences (reminders are local notifications), the selected fridge, Debug switches — are not
/// synced. Conflicts are last-writer-wins per key (the key-value store's own rule).
final class PreferenceCloudSync {
    static let syncedKeys = [UserDefaultsFavoriteCategoryStore.key, UserDefaultsFavoriteFoodStore.key]
    /// The running instance (nil when sync is off or in tests), told about local changes by the stores.
    private(set) static weak var active: PreferenceCloudSync?

    private let cloud: KeyValueCloudStore
    private let defaults: UserDefaults
    private var observer: NSObjectProtocol?
    private var applyingRemote = false

    init(cloud: KeyValueCloudStore, defaults: UserDefaults) {
        self.cloud = cloud
        self.defaults = defaults
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// First run: values already in iCloud win (another device synced first); otherwise local values are uploaded.
    func start(center: NotificationCenter = .default, observedObject: AnyObject? = nil) {
        cloud.synchronize()
        for key in Self.syncedKeys {
            if let remote = cloud.object(forKey: key) {
                applyRemote(remote, forKey: key)
            } else if let local = defaults.object(forKey: key) {
                cloud.set(local, forKey: key)
            }
        }
        observer = center.addObserver(forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
                                      object: observedObject ?? cloud, queue: .main) { [weak self] note in
            self?.receive(note)
        }
        Self.active = self
    }

    func stop() {
        if Self.active === self { Self.active = nil }
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    /// Called by the favorite stores after they saved.
    func localDidChange(key: String) {
        guard !applyingRemote, Self.syncedKeys.contains(key) else { return }
        cloud.set(defaults.object(forKey: key), forKey: key)
    }

    func receive(_ note: Notification) {
        let keys = note.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String] ?? Self.syncedKeys
        var changed = false
        for key in keys where Self.syncedKeys.contains(key) {
            applyRemote(cloud.object(forKey: key), forKey: key)
            changed = true
        }
        if changed { NotificationCenter.default.post(name: .favoritesDidChangeExternally, object: nil) }
    }

    private func applyRemote(_ value: Any?, forKey key: String) {
        applyingRemote = true
        defer { applyingRemote = false }
        defaults.set(value, forKey: key)
    }

    /// Hook for the stores (no-op unless sync runs for these defaults).
    static func noteLocalChange(key: String, defaults: UserDefaults) {
        guard let active, active.defaults === defaults else { return }
        active.localDidChange(key: key)
    }
}
