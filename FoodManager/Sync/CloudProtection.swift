import Foundation
import SwiftData
import os

/// Local recovery copies that make enabling iCloud (and account changes) safe. They live in Application Support
/// on this device only — never in iCloud — and are ordinary backups, restored through the normal preview flow.
final class ProtectionSnapshots {
    struct Snapshot: Equatable {
        enum Kind: Hashable {
            /// Taken once, before this device first synced.
            case preCloud
            /// Kept up to date for one iCloud account (by hashed account ID).
            case account(String)
            /// Kept up to date while no iCloud account was available.
            case local
            /// Taken right before a fridge is turned into a shared fridge (Phase 5D).
            case beforeSharing
            /// Taken once, before this device stopped mirroring personal data to iCloud (Phase 5E).
            case beforeLocalOnly
        }

        let kind: Kind
        let url: URL
        let modified: Date
    }

    static let shared = ProtectionSnapshots(directory: ProtectionSnapshots.defaultDirectory)
    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Backups/Protection", isDirectory: true)
    }

    static let preCloudFileName = "PreCloud-Backup.json"
    static let beforeSharingFileName = "BeforeSharing-Backup.json"
    static let beforeLocalOnlyFileName = "BeforeLocalOnly-Backup.json"
    let directory: URL
    private let logger = Logger(subsystem: "FoodManager.HowCode", category: "CloudSync")

    init(directory: URL) { self.directory = directory }

    func url(for kind: Snapshot.Kind) -> URL {
        switch kind {
        case .preCloud: return directory.appendingPathComponent(Self.preCloudFileName)
        case let .account(hash): return directory.appendingPathComponent("Account-\(hash).json")
        case .local: return directory.appendingPathComponent("Local.json")
        case .beforeSharing: return directory.appendingPathComponent(Self.beforeSharingFileName)
        case .beforeLocalOnly: return directory.appendingPathComponent(Self.beforeLocalOnlyFileName)
        }
    }

    /// Newest first.
    func list() -> [Snapshot] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.compactMap { url -> Snapshot? in
            let name = url.deletingPathExtension().lastPathComponent
            let kind: Snapshot.Kind
            if url.lastPathComponent == Self.preCloudFileName {
                kind = .preCloud
            } else if url.lastPathComponent == Self.beforeSharingFileName {
                kind = .beforeSharing
            } else if url.lastPathComponent == Self.beforeLocalOnlyFileName {
                kind = .beforeLocalOnly
            } else if name.hasPrefix("Account-") {
                kind = .account(String(name.dropFirst("Account-".count)))
            } else if name == "Local" {
                kind = .local
            } else {
                return nil
            }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return Snapshot(kind: kind, url: url, modified: modified)
        }.sorted { $0.modified > $1.modified }
    }

    /// Writes `backup` atomically and verifies it reads back as a valid backup. The previous file of the same kind
    /// is only replaced if the new one verified.
    func write(_ backup: FoodManagerBackup, kind: Snapshot.Kind) throws {
        let data = try BackupCoding.encoder().encode(backup)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = url(for: kind)
        let staging = url.appendingPathExtension("tmp")
        try data.write(to: staging, options: [.atomic, .completeFileProtection])
        do {
            _ = try BackupValidator.decode(Data(contentsOf: staging))
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: staging)
    }

    static func fingerprint(_ backup: FoodManagerBackup) -> String {
        var copy = backup
        copy.exportedAt = Date(timeIntervalSinceReferenceDate: 0)
        copy.backupID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
        let data = (try? BackupCoding.encoder().encode(BackupService.canonical(copy))) ?? Data()
        return CloudKitAccountProvider.hash(data.base64EncodedString())
    }
}

/// Phase 5E, once per device: the store earlier versions mirrored to iCloud is now opened local-only. Nothing in
/// the file changes (same location, same IDs, old iCloud records left untouched). Before the first local-only
/// session a verified JSON copy of everything is kept, and the first-run state is decided:
/// - data present → an existing installation (never asked about iCloud backups);
/// - empty store → a new installation: the app may offer restoring an iCloud backup (`FirstRunState.pending`).
enum LocalOnlyMigration {
    private static let logger = Logger(subsystem: "FoodManager.HowCode", category: "Persistence")
    static let doneKey = "personalStorage.localOnlyMigrated"

    enum Outcome: Equatable {
        case alreadyDone
        case existingData
        case freshInstall
        /// Data present but the protection copy couldn't be written; retried on the next launch.
        case snapshotFailed
    }

    @discardableResult
    static func runIfNeeded(container: ModelContainer, snapshots: ProtectionSnapshots, magnetImages: MagnetImageStore?,
                            defaults: UserDefaults = .standard,
                            preferences: PreferencesBackupStore = UserDefaultsPreferencesBackupStore(selection: UserDefaultsFridgeSelectionStore())) -> Outcome {
        guard !defaults.bool(forKey: doneKey) else { return .alreadyDone }
        let hasData = !((try? SwiftDataFridgeStore(container: container).existingIDs()) ?? []).isEmpty
        guard hasData else {
            if FirstRunState.load(defaults) == nil { FirstRunState.pending.save(defaults) }
            defaults.set(true, forKey: doneKey)
            return .freshInstall
        }
        // An existing installation never gets the "found an iCloud backup" question.
        if FirstRunState.load(defaults) == nil { FirstRunState.decided.save(defaults) }
        do {
            let service = BackupService(inventory: SwiftDataInventoryBackupStore(container: container), preferences: preferences,
                                        magnetImages: magnetImages, recoveryDirectory: nil)
            try snapshots.write(try service.makeBackup(allowMissingPhotos: true), kind: .beforeLocalOnly)
            defaults.set(true, forKey: doneKey)
            return .existingData
        } catch {
            logger.error("Local-only migration snapshot failed; will retry: \(String(describing: error), privacy: .private)")
            return .snapshotFailed
        }
    }
}

/// Whether a new installation still has to choose between restoring an iCloud backup and starting fresh.
enum FirstRunState: String {
    case pending
    case decided

    static let key = "personalStorage.firstRunChoice"

    static func load(_ defaults: UserDefaults = .standard) -> FirstRunState? {
        defaults.string(forKey: key).flatMap(FirstRunState.init(rawValue:))
    }

    func save(_ defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.key)
    }
}
