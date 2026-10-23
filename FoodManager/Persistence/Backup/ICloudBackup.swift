import CloudKit
import CryptoKit
import Foundation
import os

// Phase 5E: personal data reaches iCloud only when the user asks for a backup, and comes back only when the user
// picks a version and confirms the restore. Nothing here runs on its own.
//
// Storage: the user's private database, custom zone `PersonalBackups` (separate from the old SwiftData mirror zone
// and from shared fridges). One immutable `PersonalBackup` record per version: metadata fields plus the regular JSON
// backup file (with magnet photos) as a CKAsset. A record is saved in one operation, so an interrupted upload leaves
// no version behind; a version only counts once it has been downloaded again and its SHA-256 matches.

/// What a backup version contains (metadata only; listing never downloads the data).
struct ICloudBackupVersion: Equatable {
    let id: String
    let createdAt: Date
    let appVersion: String
    let formatVersion: Int
    let fridgeCount: Int
    let activeFoodCount: Int
    let historyCount: Int
    let magnetCount: Int
    let imageCount: Int
    let byteCount: Int
    let sha256: String

    init(id: String, createdAt: Date, appVersion: String, formatVersion: Int, fridgeCount: Int, activeFoodCount: Int,
         historyCount: Int, magnetCount: Int, imageCount: Int, byteCount: Int, sha256: String) {
        self.id = id
        self.createdAt = createdAt
        self.appVersion = appVersion
        self.formatVersion = formatVersion
        self.fridgeCount = fridgeCount
        self.activeFoodCount = activeFoodCount
        self.historyCount = historyCount
        self.magnetCount = magnetCount
        self.imageCount = imageCount
        self.byteCount = byteCount
        self.sha256 = sha256
    }

    /// Metadata of `backup` encoded as `data`.
    init(backup: FoodManagerBackup, data: Data, id: String = UUID().uuidString) {
        self.init(id: id, createdAt: backup.exportedAt, appVersion: backup.applicationVersion, formatVersion: backup.formatVersion,
                  fridgeCount: backup.fridges.count,
                  activeFoodCount: backup.foods.filter { $0.consumedAt == nil }.count,
                  historyCount: backup.foods.filter { $0.consumedAt != nil }.count,
                  magnetCount: backup.allMagnets.count, imageCount: backup.allMagnetImages.count,
                  byteCount: data.count, sha256: Self.digest(data))
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

enum ICloudBackupError: Error, Equatable {
    case noAccount
    case accountRestricted
    case networkUnavailable
    case quotaExceeded
    /// The uploaded copy didn't read back identically; the previous versions are untouched.
    case verificationFailed
    /// The downloaded copy doesn't match its checksum or isn't a valid backup; nothing was changed.
    case corrupted
    case versionGone
    case failed(code: Int)

    var message: String {
        switch self {
        case .noAccount: return "請先在「設定 → Apple 帳號」登入 iCloud，並允許冰箱管理員使用 iCloud。"
        case .accountRestricted: return "這台裝置的 iCloud 受到限制，無法使用 iCloud 備份。"
        case .networkUnavailable: return "目前無法連線到 iCloud，請確認網路後再試。資料沒有變更。"
        case .quotaExceeded: return "iCloud 儲存空間不足，這次備份沒有完成。之前的備份仍然保留。"
        case .verificationFailed: return "上傳後的檢查沒有通過，這次備份不算數。之前的備份仍然保留。"
        case .corrupted: return "這份 iCloud 備份無法通過檢查（可能下載不完整），目前的資料沒有變更。"
        case .versionGone: return "這份備份已經不在 iCloud 上了，請重新整理後再選一次。"
        case let .failed(code): return "iCloud 備份沒有完成（CloudKit 錯誤 \(code)），資料沒有變更，請稍後再試。"
        }
    }

    static func from(_ error: Error) -> ICloudBackupError {
        if let error = error as? ICloudBackupError { return error }
        guard let ckError = error as? CKError else { return .failed(code: -1) }
        switch ckError.code {
        case .notAuthenticated: return .noAccount
        case .networkUnavailable, .networkFailure, .serviceUnavailable, .requestRateLimited, .zoneBusy: return .networkUnavailable
        case .quotaExceeded: return .quotaExceeded
        case .unknownItem: return .versionGone
        case .partialFailure:
            let first = ckError.partialErrorsByItemID?.values.first
            return first.map(from) ?? .failed(code: ckError.code.rawValue)
        default: return .failed(code: ckError.code.rawValue)
        }
    }
}

/// The CloudKit side (live: `CloudKitBackupStore`; tests: an in-memory fake).
protocol ICloudBackupStore: AnyObject {
    func accountState() async -> CloudAccountState
    /// Complete versions, metadata only.
    func versions() async throws -> [ICloudBackupVersion]
    func upload(_ version: ICloudBackupVersion, data: Data) async throws
    func download(id: String) async throws -> Data
    func delete(ids: [String]) async throws
}

final class ICloudBackupService {
    static let retainedVersions = 3
    private let store: ICloudBackupStore
    private let defaults: UserDefaults
    private let logger = Logger(subsystem: "FoodManager.HowCode", category: "ICloudBackup")
    static let lastVerifiedKey = "icloudBackup.lastVerifiedAt"

    init(store: ICloudBackupStore, defaults: UserDefaults = .standard) {
        self.store = store
        self.defaults = defaults
    }

    /// When this device last made a backup that verified (shown in 設定; never set before verification).
    var lastVerifiedBackup: Date? { defaults.object(forKey: Self.lastVerifiedKey) as? Date }

    func requireAccount() async throws {
        switch await store.accountState() {
        case .available: return
        case .restricted: throw ICloudBackupError.accountRestricted
        case .noAccount: throw ICloudBackupError.noAccount
        case .temporarilyUnavailable, .unknown: throw ICloudBackupError.networkUnavailable
        }
    }

    /// Newest first.
    func versions() async throws -> [ICloudBackupVersion] {
        do {
            try await requireAccount()
            return try await store.versions().sorted { $0.createdAt > $1.createdAt }
        } catch {
            throw ICloudBackupError.from(error)
        }
    }

    /// Uploads `backup` as a new version, verifies it by reading it back, and only then removes versions beyond
    /// the newest three. A failure at any point leaves every earlier version as it was.
    func upload(_ backup: FoodManagerBackup) async throws -> ICloudBackupVersion {
        do {
            try await requireAccount()
            try BackupValidator.validate(backup)
            let data = try BackupCoding.encoder().encode(backup)
            let version = ICloudBackupVersion(backup: backup, data: data)
            try await store.upload(version, data: data)
            let readBack = try await store.download(id: version.id)
            guard ICloudBackupVersion.digest(readBack) == version.sha256 else {
                try? await store.delete(ids: [version.id])
                throw ICloudBackupError.verificationFailed
            }
            defaults.set(version.createdAt, forKey: Self.lastVerifiedKey)
            await removeOldVersions(keeping: version.id)
            return version
        } catch {
            logger.error("iCloud backup failed: \(String(describing: ICloudBackupError.from(error)), privacy: .public)")
            throw ICloudBackupError.from(error)
        }
    }

    /// Downloads one version and checks it completely (checksum, then every backup rule). Changes nothing.
    func download(_ version: ICloudBackupVersion) async throws -> FoodManagerBackup {
        let data: Data
        do {
            try await requireAccount()
            data = try await store.download(id: version.id)
        } catch {
            throw ICloudBackupError.from(error)
        }
        guard ICloudBackupVersion.digest(data) == version.sha256,
              let backup = try? BackupValidator.decode(data) else { throw ICloudBackupError.corrupted }
        return backup
    }

    /// Cleanup after a verified upload: only versions older than the newest `retainedVersions` (never the new one).
    private func removeOldVersions(keeping newID: String) async {
        guard let all = try? await store.versions().sorted(by: { $0.createdAt > $1.createdAt }) else { return }
        var kept = all.filter { $0.id == newID }
        for version in all where version.id != newID && kept.count < Self.retainedVersions { kept.append(version) }
        let keptIDs = Set(kept.map(\.id))
        let old = all.map(\.id).filter { !keptIDs.contains($0) }
        guard !old.isEmpty else { return }
        do {
            try await store.delete(ids: old)
        } catch {
            logger.notice("Old iCloud backups not removed yet; next backup retries")
        }
    }
}

// MARK: - Live CloudKit

final class CloudKitBackupStore: ICloudBackupStore {
    static let zoneID = CKRecordZone.ID(zoneName: "PersonalBackups", ownerName: CKCurrentUserDefaultName)
    static let recordType = "PersonalBackup"
    private let container: CKContainer
    private var database: CKDatabase { container.privateCloudDatabase }
    private let account: CloudAccountProvider

    init(container: CKContainer = CKContainer(identifier: CloudSyncConstants.containerIdentifier),
         account: CloudAccountProvider = CloudKitAccountProvider()) {
        self.container = container
        self.account = account
    }

    func accountState() async -> CloudAccountState { await account.accountState() }

    func versions() async throws -> [ICloudBackupVersion] {
        var result: [ICloudBackupVersion] = []
        var token: CKServerChangeToken?
        var more = true
        while more {
            let changes: (modificationResultsByID: [CKRecord.ID: Result<CKDatabase.RecordZoneChange.Modification, Error>],
                          deletions: [CKDatabase.RecordZoneChange.Deletion], changeToken: CKServerChangeToken, moreComing: Bool)
            do {
                changes = try await database.recordZoneChanges(inZoneWith: Self.zoneID, since: token,
                                                               desiredKeys: Self.metadataKeys, resultsLimit: nil)
            } catch let error as CKError where error.code == .zoneNotFound || error.code == .userDeletedZone {
                return [] // never backed up from this account
            }
            for case let .success(modification) in changes.modificationResultsByID.values {
                if let version = Self.version(from: modification.record) { result.append(version) }
            }
            token = changes.changeToken
            more = changes.moreComing
        }
        return result
    }

    func upload(_ version: ICloudBackupVersion, data: Data) async throws {
        _ = try await database.modifyRecordZones(saving: [CKRecordZone(zoneID: Self.zoneID)], deleting: [])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ICloudBackupUpload", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("\(version.id).json")
        try data.write(to: file, options: [.atomic, .completeFileProtection])
        defer { try? FileManager.default.removeItem(at: file) }

        let record = CKRecord(recordType: Self.recordType, recordID: CKRecord.ID(recordName: version.id, zoneID: Self.zoneID))
        record["createdAt"] = version.createdAt
        record["appVersion"] = version.appVersion
        record["formatVersion"] = NSNumber(value: version.formatVersion)
        record["fridgeCount"] = NSNumber(value: version.fridgeCount)
        record["activeFoodCount"] = NSNumber(value: version.activeFoodCount)
        record["historyCount"] = NSNumber(value: version.historyCount)
        record["magnetCount"] = NSNumber(value: version.magnetCount)
        record["imageCount"] = NSNumber(value: version.imageCount)
        record["byteCount"] = NSNumber(value: version.byteCount)
        record["sha256"] = version.sha256
        record["payload"] = CKAsset(fileURL: file)
        let (results, _) = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .allKeys)
        for result in results.values { _ = try result.get() }
    }

    func download(id: String) async throws -> Data {
        let record = try await database.record(for: CKRecord.ID(recordName: id, zoneID: Self.zoneID))
        guard let url = (record["payload"] as? CKAsset)?.fileURL else { throw ICloudBackupError.corrupted }
        return try Data(contentsOf: url)
    }

    func delete(ids: [String]) async throws {
        let recordIDs = ids.map { CKRecord.ID(recordName: $0, zoneID: Self.zoneID) }
        let (_, results) = try await database.modifyRecords(saving: [], deleting: recordIDs, atomically: false)
        for result in results.values {
            do {
                try result.get()
            } catch let error as CKError where error.code == .unknownItem {
                continue
            }
        }
    }

    private static let metadataKeys = ["createdAt", "appVersion", "formatVersion", "fridgeCount", "activeFoodCount", "historyCount",
                                       "magnetCount", "imageCount", "byteCount", "sha256"]

    private static func version(from record: CKRecord) -> ICloudBackupVersion? {
        guard record.recordType == recordType, let createdAt = record["createdAt"] as? Date,
              let sha = record["sha256"] as? String, let bytes = (record["byteCount"] as? NSNumber)?.intValue else { return nil }
        func int(_ key: String) -> Int { (record[key] as? NSNumber)?.intValue ?? 0 }
        return ICloudBackupVersion(id: record.recordID.recordName, createdAt: createdAt, appVersion: record["appVersion"] as? String ?? "",
                                   formatVersion: int("formatVersion"), fridgeCount: int("fridgeCount"),
                                   activeFoodCount: int("activeFoodCount"), historyCount: int("historyCount"),
                                   magnetCount: int("magnetCount"), imageCount: int("imageCount"), byteCount: bytes, sha256: sha)
    }
}
