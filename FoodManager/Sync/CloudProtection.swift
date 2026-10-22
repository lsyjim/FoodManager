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
    let directory: URL
    private let logger = Logger(subsystem: "FoodManager.HowCode", category: "CloudSync")

    init(directory: URL) { self.directory = directory }

    func url(for kind: Snapshot.Kind) -> URL {
        switch kind {
        case .preCloud: return directory.appendingPathComponent(Self.preCloudFileName)
        case let .account(hash): return directory.appendingPathComponent("Account-\(hash).json")
        case .local: return directory.appendingPathComponent("Local.json")
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

    /// Updates the rolling snapshot for the current account (or for "no account") if the data changed.
    /// A snapshot of one account is never overwritten while another account is signed in.
    func refresh(using backups: BackupService, settings: CloudSyncSettings, account: String?) {
        do {
            let backup = try backups.makeBackup(allowMissingPhotos: true)
            let fingerprint = Self.fingerprint(backup) + (account ?? "-")
            guard fingerprint != settings.protectionFingerprint else { return }
            try write(backup, kind: account.map(Snapshot.Kind.account) ?? .local)
            settings.protectionFingerprint = fingerprint
        } catch {
            logger.error("Protection snapshot failed: \(String(describing: error), privacy: .private)")
        }
    }

    static func fingerprint(_ backup: FoodManagerBackup) -> String {
        var copy = backup
        copy.exportedAt = Date(timeIntervalSinceReferenceDate: 0)
        copy.backupID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
        let data = (try? BackupCoding.encoder().encode(BackupService.canonical(copy))) ?? Data()
        return CloudKitAccountProvider.hash(data.base64EncodedString())
    }
}

/// One-time preparation before a device first opens its store with CloudKit (policy A). Nothing is deleted,
/// moved or replaced; if any step fails, the app keeps working locally and sync stays off until it succeeds.
///
/// 1. Copy the raw store files (before the schema upgrade touches them).
/// 2. Open the store locally (lightweight migration: unique constraints removed, defaults added).
/// 3. Give existing local magnet photos synced image records.
/// 4. Write a JSON backup of everything and verify it reads back.
enum CloudSyncPreparation {
    private static let logger = Logger(subsystem: "FoodManager.HowCode", category: "CloudSync")

    enum Outcome: Equatable {
        case ready
        case failed(String)
    }

    static func prepareIfNeeded(storeURL: URL, settings: CloudSyncSettings, snapshots: ProtectionSnapshots,
                                magnetImageDirectory: URL, rawCopyDirectory: URL? = nil,
                                preferences: PreferencesBackupStore = UserDefaultsPreferencesBackupStore(selection: UserDefaultsFridgeSelectionStore()),
                                openLocal: (URL) throws -> ModelContainer = { try SwiftDataFridgeStore.makeContainer(url: $0) }) -> Outcome {
        guard !settings.isPreparedForCloud else { return .ready }
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: storeURL.path) else {
            // Fresh install: nothing local to protect.
            settings.isPreparedForCloud = true
            return .ready
        }
        do {
            let copyRoot = rawCopyDirectory ?? snapshots.directory.appendingPathComponent("PreCloud-Store", isDirectory: true)
            try copyStoreFiles(storeURL, to: copyRoot)
            try autoreleasepool {
                let container = try openLocal(storeURL)
                let images = MagnetImageStore(directory: magnetImageDirectory)
                let library = MagnetLibrary(store: SwiftDataMagnetStore(container: container), images: images)
                try library.backfillImageRecords()
                let service = BackupService(inventory: SwiftDataInventoryBackupStore(container: container),
                                            preferences: preferences,
                                            magnetImages: images, recoveryDirectory: nil)
                try snapshots.write(try service.makeBackup(allowMissingPhotos: true), kind: .preCloud)
            }
            settings.isPreparedForCloud = true
            return .ready
        } catch {
            logger.error("Pre-sync preparation failed: \(String(describing: error), privacy: .private)")
            return .failed("無法建立同步前的保護副本，iCloud 同步暫不開啟，資料仍保存在這台裝置上。")
        }
    }

    /// Copies the store and its -wal / -shm files and checks the sizes match. An existing copy is kept.
    static func copyStoreFiles(_ storeURL: URL, to directory: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        for suffix in ["", "-wal", "-shm"] {
            let source = URL(fileURLWithPath: storeURL.path + suffix)
            guard fileManager.fileExists(atPath: source.path) else { continue }
            let target = directory.appendingPathComponent(source.lastPathComponent)
            if fileManager.fileExists(atPath: target.path) { continue }
            try fileManager.copyItem(at: source, to: target)
            let a = try fileManager.attributesOfItem(atPath: source.path)[.size] as? Int
            let b = try fileManager.attributesOfItem(atPath: target.path)[.size] as? Int
            guard a == b else { throw CocoaError(.fileWriteUnknown) }
        }
    }
}
