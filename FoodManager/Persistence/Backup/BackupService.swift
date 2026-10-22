import Foundation
import os

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
    /// Where the pre-restore copy is kept (Application Support). nil for in-memory test sessions.
    private let recoveryDirectory: URL?
    private let exportDirectory: URL
    private let now: () -> Date
    private let applicationVersion: String
    private let fileManager = FileManager.default
    private let logger = Logger(subsystem: "FoodManager.HowCode", category: "Backup")

    static let recoveryFileName = "PreRestore-Backup.json"

    init(inventory: InventoryBackupStore, preferences: PreferencesBackupStore, recoveryDirectory: URL?,
         exportDirectory: URL = FileManager.default.temporaryDirectory.appendingPathComponent("BackupExport", isDirectory: true),
         now: @escaping () -> Date = Date.init,
         applicationVersion: String = BackupService.bundleVersion) {
        self.inventory = inventory
        self.preferences = preferences
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
    func makeBackup() throws -> FoodManagerBackup {
        let backup = try currentBackup()
        try BackupValidator.validate(backup)
        return backup
    }

    /// Writes the backup to a fresh temporary file and returns its URL only once the file exists and decodes.
    func exportFile() throws -> URL {
        let backup = try makeBackup()
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
        let target = Self.canonical(backup)

        // 1. Recovery snapshot, in memory and on disk, before anything changes.
        let previous: FoodManagerBackup
        do {
            previous = try currentBackup()
        } catch {
            throw BackupError.currentDataUnreadable
        }
        try writeRecoveryFile(previous)

        // 2. Database: one save. If it fails, SwiftData rolled it back and nothing changed.
        do {
            try inventory.replaceInventory(fridges: target.fridges, foods: target.foods)
        } catch {
            logger.error("Restore: database replace failed: \(String(describing: error), privacy: .private)")
            throw BackupError.saveFailed
        }

        // 3. Preferences, then 4. verify everything by reading it back.
        do {
            try preferences.writePreferences(target.preferences)
            guard try currentBackup().hasSameContent(as: target) else { throw BackupError.saveFailed }
        } catch {
            logger.error("Restore failed after the database changed; rolling back: \(String(describing: error), privacy: .private)")
            throw BackupError.restoreFailed(rolledBack: rollBack(to: previous))
        }
    }

    /// Writes the snapshot back. Returns whether the previous data is verifiably back.
    private func rollBack(to previous: FoodManagerBackup) -> Bool {
        do {
            try inventory.replaceInventory(fridges: previous.fridges, foods: previous.foods)
            try preferences.writePreferences(previous.preferences)
            return try currentBackup().hasSameContent(as: previous)
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

    private func currentBackup() throws -> FoodManagerBackup {
        let stored = try inventory.readInventory()
        return FoodManagerBackup(formatVersion: FoodManagerBackup.currentFormatVersion, exportedAt: now(),
                                 applicationVersion: applicationVersion, backupID: UUID(),
                                 fridges: stored.fridges, foods: stored.foods, preferences: preferences.readPreferences())
    }

    /// The exact form the stores read back: quantities re-encoded ("1.50" → "1.5"), and a selected fridge
    /// that isn't in the backup replaced with its first fridge.
    static func canonical(_ backup: FoodManagerBackup) -> FoodManagerBackup {
        var result = backup
        result.fridges = backup.fridges.map { BackupFridge($0.fridge, createdAt: $0.createdAt) }
        result.foods = backup.foods.map { BackupFood($0.item) }
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
