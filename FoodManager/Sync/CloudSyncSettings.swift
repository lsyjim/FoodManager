import CloudKit
import CryptoKit
import Foundation

enum CloudSyncConstants {
    /// The app's CloudKit container. Data lives in each user's *private* database only.
    static let containerIdentifier = "iCloud.FoodManager.HowCode"
}

/// Device-local sync settings (never synced themselves).
final class CloudSyncSettings {
    static let shared = CloudSyncSettings(defaults: .standard)

    private let defaults: UserDefaults
    private enum Key {
        static let enabled = "cloudSync.enabled"
        static let prepared = "cloudSync.preparedForCloud"
        static let account = "cloudSync.accountFingerprint"
        static let pendingAccountNotice = "cloudSync.pendingAccountNotice"
        static let snapshotFingerprint = "cloudSync.protectionFingerprint"
    }

    init(defaults: UserDefaults) { self.defaults = defaults }

    /// User switch (設定 → 資料管理 → iCloud 自動同步). On by default.
    var isEnabled: Bool {
        get { defaults.object(forKey: Key.enabled) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.enabled) }
    }

    /// The one-time pre-sync protection (raw store copy + verified JSON backup) finished on this device.
    var isPreparedForCloud: Bool {
        get { defaults.bool(forKey: Key.prepared) }
        set { defaults.set(newValue, forKey: Key.prepared) }
    }

    /// Hash of the iCloud user this device last synced with (the raw record ID is never stored).
    var accountFingerprint: String? {
        get { defaults.string(forKey: Key.account) }
        set { defaults.set(newValue, forKey: Key.account) }
    }

    /// Set when a different iCloud account was detected; cleared once the user saw the explanation.
    var hasPendingAccountNotice: Bool {
        get { defaults.bool(forKey: Key.pendingAccountNotice) }
        set { defaults.set(newValue, forKey: Key.pendingAccountNotice) }
    }

    /// Content fingerprint of the last protection snapshot (skip rewriting an unchanged one).
    var protectionFingerprint: String? {
        get { defaults.string(forKey: Key.snapshotFingerprint) }
        set { defaults.set(newValue, forKey: Key.snapshotFingerprint) }
    }
}

enum CloudAccountState: Equatable {
    case available
    case noAccount
    case restricted
    case temporarilyUnavailable
    case unknown

    var isAvailable: Bool { self == .available }
}

/// The iCloud account, behind a protocol so tests never touch CloudKit.
protocol CloudAccountProvider {
    func accountState() async -> CloudAccountState
    /// A stable, hashed identifier of the signed-in iCloud user for this app's container (nil if unknown).
    func accountFingerprint() async -> String?
}

struct CloudKitAccountProvider: CloudAccountProvider {
    private var container: CKContainer { CKContainer(identifier: CloudSyncConstants.containerIdentifier) }

    func accountState() async -> CloudAccountState {
        guard let status = try? await container.accountStatus() else { return .unknown }
        switch status {
        case .available: return .available
        case .noAccount: return .noAccount
        case .restricted: return .restricted
        case .temporarilyUnavailable: return .temporarilyUnavailable
        default: return .unknown
        }
    }

    func accountFingerprint() async -> String? {
        guard let recordID = try? await container.userRecordID() else { return nil }
        return Self.hash(recordID.recordName)
    }

    static func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}

/// What to do when the signed-in account is checked (policy A).
enum CloudAccountTransition: Equatable {
    /// First time this device syncs with any account: remember it.
    case firstAccount(String)
    case sameAccount
    /// A different iCloud user than last time. iOS replaces the synced data with the new account's data; the
    /// previous account's data stays in its local protection snapshot, which the user can restore explicitly.
    case accountChanged(String)
    /// Signed out / unavailable: nothing is deleted by the app; local data stays usable offline.
    case unavailable

    static func evaluate(stored: String?, current: String?, state: CloudAccountState) -> CloudAccountTransition {
        guard state.isAvailable, let current else { return .unavailable }
        guard let stored else { return .firstAccount(current) }
        return stored == current ? .sameAccount : .accountChanged(current)
    }
}
