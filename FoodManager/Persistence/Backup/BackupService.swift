import Foundation
import os

/// Shared refrigerators (Phase 5D) live outside backups: never exported, never replaced by a restore.
struct SharedFridgeExclusion: Equatable {
    var fridgeIDs: Set<UUID>
    /// Shared fridges that count toward the limit, plus access requests waiting for approval.
    var reservedSlots: Int

    static let none = SharedFridgeExclusion(fridgeIDs: [], reservedSlots: 0)
}

/// Export, import and full-replacement restore of the user's data.
///
/// Atomicity: fridges and food live in SwiftData and are replaced in a single `ModelContext.save()`, which is
/// atomic for the database. Preferences live in UserDefaults, which has no transactions with SwiftData. So a
/// restore is staged: recovery snapshot → database replace (one save) → preferences → read-back verification.
/// If any step after the database replace fails, the snapshot is written back the same way. A crash between
/// the two writes can still leave new food with old preferences; the pre-restore copy stays on disk for that.
final class BackupService {
    private let inventory: InventoryBackupStore
    private let preferences: PreferencesBackupStore
    /// Magnet photo files (nil: this store has no magnet images, e.g. in some tests).
    private let magnetImages: MagnetImageStore?
    /// Where the pre-restore copy is kept (Application Support). nil for in-memory test sessions.
    private let recoveryDirectory: URL?
    private let exportDirectory: URL
    private let now: () -> Date
    private let applicationVersion: String
    private let fileManager = FileManager.default
    private let logger = Logger(subsystem: "FoodManager.HowCode", category: "Backup")
    /// Shared fridges on this device (a backup only ever covers personal fridges).
    var sharedFridges: () -> SharedFridgeExclusion = { .none }

    static let recoveryFileName = "PreRestore-Backup.json"

    init(inventory: InventoryBackupStore, preferences: PreferencesBackupStore, magnetImages: MagnetImageStore? = nil,
         recoveryDirectory: URL?,
         exportDirectory: URL = FileManager.default.temporaryDirectory.appendingPathComponent("BackupExport", isDirectory: true),
         now: @escaping () -> Date = Date.init,
         applicationVersion: String = BackupService.bundleVersion) {
        self.inventory = inventory
        self.preferences = preferences
        self.magnetImages = magnetImages
        self.recoveryDirectory = recoveryDirectory
        self.exportDirectory = exportDirectory
        self.now = now
        self.applicationVersion = applicationVersion
    }

    static var bundleVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    static var defaultRecoveryDirectory: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Backups", isDirectory: true)
    }

    var recoveryFileURL: URL? { recoveryDirectory?.appendingPathComponent(Self.recoveryFileName) }

    // MARK: - Export

    /// Everything currently stored, validated with the same rules as an import.
    /// Throws `magnetImageMissing` rather than silently exporting a backup without a photo. With
    /// `allowMissingPhotos` (the user agreed), such magnets are exported without their photo and restore as a
    /// blank card in the same place — e.g. while a photo is still downloading from iCloud.
    func makeBackup(allowMissingPhotos: Bool = false) throws -> FoodManagerBackup {
        let backup = try currentBackup(requireImages: !allowMissingPhotos)
        do {
            try BackupValidator.validate(backup)
        } catch BackupError.noFridges where !sharedFridges().fridgeIDs.isEmpty {
            throw BackupError.onlySharedFridges
        }
        return backup
    }

    /// Whether a validated backup may replace the personal data here: it must not overwrite a shared fridge, and
    /// together with the shared fridges it must stay within the limit. Checked before the preview's confirm button
    /// and again by `restore`.
    func checkRestorable(_ backup: FoodManagerBackup) throws {
        let shared = sharedFridges()
        if let clash = backup.fridges.first(where: { shared.fridgeIDs.contains($0.id) }) {
            throw BackupError.sharedFridgeConflict(clash.name)
        }
        if backup.fridges.count + shared.reservedSlots > FridgePolicy.maxRefrigerators {
            throw BackupError.sharedLimit(sharedCount: shared.reservedSlots)
        }
    }

    /// Writes the backup to a fresh temporary file and returns its URL only once the file exists and decodes.
    func exportFile(allowMissingPhotos: Bool = false) throws -> URL {
        let backup = try makeBackup(allowMissingPhotos: allowMissingPhotos)
        let data: Data
        do {
            data = try BackupCoding.encoder().encode(backup)
        } catch {
            throw BackupError.exportFailed
        }
        cleanUpExports()
        let url = exportDirectory.appendingPathComponent(Self.fileName(for: backup.exportedAt))
        do {
            try fileManager.createDirectory(at: exportDirectory, withIntermediateDirectories: true)
            try data.write(to: url, options: [.atomic, .completeFileProtection])
        } catch {
            cleanUpExports()
            throw Self.isOutOfSpace(error) ? BackupError.insufficientStorage : BackupError.exportFailed
        }
        guard let written = try? Data(contentsOf: url), written == data else {
            cleanUpExports()
            throw BackupError.exportFailed
        }
        return url
    }

    /// Removes temporary export files (after sharing finished or was cancelled).
    func cleanUpExports() {
        try? fileManager.removeItem(at: exportDirectory)
    }

    static func fileName(for date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "FoodManager-Backup-%04d-%02d-%02d.json", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    // MARK: - Import

    /// Reads and fully validates a picked file. Never touches stored data.
    static func readBackup(at url: URL, maxFileSize: Int = BackupValidator.maxFileSize) throws -> FoodManagerBackup {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        // Reject oversized files before loading them into memory.
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > maxFileSize {
            throw BackupError.fileTooLarge(size)
        }
        let data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw BackupError.unreadable
        }
        return try BackupValidator.decode(data, maxFileSize: maxFileSize)
    }

    // MARK: - Restore

    /// Replaces ALL current data with the backup. Returns only after the new data is committed and read back.
    /// Throws without changing anything (or after restoring the previous data — see `BackupError.restoreFailed`).
    func restore(_ backup: FoodManagerBackup) throws {
        try BackupValidator.validate(backup)
        try checkRestorable(backup)
        let target = Self.canonical(backup)

        // 1. Recovery snapshot, in memory and on disk, before anything changes. A photo whose file is already
        //    missing can't be part of it; that doesn't block the restore.
        let previous: FoodManagerBackup
        do {
            previous = try currentBackup(requireImages: false)
        } catch {
            throw BackupError.currentDataUnreadable
        }
        try writeRecoveryFile(previous)

        // 2. Magnet photos first (new files only add; nothing references them until the database says so),
        //    then the database in one save. If either fails, the stored data is unchanged.
        do {
            try writeImages(target.allMagnetImages)
            try inventory.replaceInventory(Self.inventory(of: target))
        } catch {
            logger.error("Restore: database replace failed: \(String(describing: error), privacy: .private)")
            removeUnreferencedImages()
            throw BackupError.saveFailed
        }

        // 3. Preferences, then 4. verify everything by reading it back.
        do {
            try preferences.writePreferences(target.preferences)
            guard try currentBackup(requireImages: false).hasSameContent(as: target) else { throw BackupError.saveFailed }
        } catch {
            logger.error("Restore failed after the database changed; rolling back: \(String(describing: error), privacy: .private)")
            let rolledBack = rollBack(to: previous)
            removeUnreferencedImages()
            throw BackupError.restoreFailed(rolledBack: rolledBack)
        }
        removeUnreferencedImages()
    }

    /// Writes the snapshot back. Returns whether the previous data is verifiably back.
    private func rollBack(to previous: FoodManagerBackup) -> Bool {
        do {
            try writeImages(previous.allMagnetImages)
            try inventory.replaceInventory(Self.inventory(of: previous))
            try preferences.writePreferences(previous.preferences)
            return try currentBackup(requireImages: false).hasSameContent(as: previous)
        } catch {
            logger.error("Restore rollback failed: \(String(describing: error), privacy: .private)")
            return false
        }
    }

    private func writeRecoveryFile(_ snapshot: FoodManagerBackup) throws {
        guard let recoveryDirectory, let url = recoveryFileURL else { return }
        do {
            try fileManager.createDirectory(at: recoveryDirectory, withIntermediateDirectories: true)
            try BackupCoding.encoder().encode(snapshot).write(to: url, options: [.atomic, .completeFileProtection])
        } catch {
            logger.error("Restore: recovery snapshot failed: \(String(describing: error), privacy: .private)")
            throw BackupError.recoverySnapshotFailed
        }
    }

    private func currentBackup(requireImages: Bool) throws -> FoodManagerBackup {
        let stored = try inventory.readInventory()
        var images: [BackupMagnetImage] = []
        for id in Set(stored.magnets.compactMap(\.localImageID)).sorted(by: { $0.uuidString < $1.uuidString }) {
            if let data = magnetImages?.data(id) ?? stored.images[id] {
                images.append(BackupMagnetImage(id: id, data: data))
            } else if requireImages {
                throw BackupError.magnetImageMissing
            }
        }
        return FoodManagerBackup(formatVersion: FoodManagerBackup.currentFormatVersion, exportedAt: now(),
                                 applicationVersion: applicationVersion, backupID: UUID(),
                                 fridges: stored.fridges, foods: stored.foods, preferences: preferences.readPreferences(),
                                 magnets: stored.magnets, magnetImages: images)
    }

    private static func inventory(of backup: FoodManagerBackup) -> StoredInventory {
        StoredInventory(fridges: backup.fridges, foods: backup.foods, magnets: backup.allMagnets,
                        images: Dictionary(backup.allMagnetImages.map { ($0.id, $0.data) }, uniquingKeysWith: { first, _ in first }))
    }

    private func writeImages(_ images: [BackupMagnetImage]) throws {
        guard let magnetImages else { return }
        for image in images { try magnetImages.storeImageData(image.data, id: image.id) }
    }

    private func removeUnreferencedImages() {
        guard let magnetImages, let stored = try? inventory.readInventory() else { return }
        magnetImages.removeUnreferenced(keeping: Set(stored.magnets.compactMap(\.localImageID)))
    }

    /// The exact form the stores read back: quantities re-encoded ("1.50" → "1.5"), and a selected fridge
    /// that isn't in the backup replaced with its first fridge.
    static func canonical(_ backup: FoodManagerBackup) -> FoodManagerBackup {
        var result = backup
        result.fridges = backup.fridges.map { BackupFridge($0.fridge, createdAt: $0.createdAt) }
        result.foods = backup.foods.map { BackupFood($0.item) }
        result.magnets = backup.allMagnets
        // Only photos some magnet uses are stored (and read back).
        let used = Set(backup.allMagnets.compactMap(\.localImageID))
        result.magnetImages = backup.allMagnetImages.filter { used.contains($0.id) }
        let ids = Set(backup.fridges.map(\.id))
        if backup.preferences.selectedFridgeID.map(ids.contains) != true {
            result.preferences.selectedFridgeID = backup.fridges.min { $0.createdAt < $1.createdAt }?.id
        }
        return result
    }

    private static func isOutOfSpace(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileWriteOutOfSpaceError { return true }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            return underlying.domain == NSPOSIXErrorDomain && underlying.code == Int(ENOSPC)
        }
        return false
    }
}
