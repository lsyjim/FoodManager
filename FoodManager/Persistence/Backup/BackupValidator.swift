import Foundation

enum BackupError: Error, Equatable {
    case fileTooLarge(Int)
    case unreadable
    case notABackup
    case malformed
    case unsupportedVersion(Int)
    case tooManyRecords
    case noFridges
    case tooManyFridges(Int)
    case duplicateIDs
    case invalidLayout(String)
    case invalidFood(String)
    case invalidCompartmentReference(String)
    case invalidPreferences
    /// Current data couldn't be read, so no recovery snapshot exists: nothing was changed.
    case currentDataUnreadable
    /// The recovery copy couldn't be written (e.g. no free space): nothing was changed.
    case recoverySnapshotFailed
    case saveFailed
    case exportFailed
    case insufficientStorage
    /// Restoring failed after the database changed; `rolledBack` says whether the previous data is back.
    case restoreFailed(rolledBack: Bool)

    var message: String {
        switch self {
        case let .fileTooLarge(bytes): return "檔案太大（\(bytes / 1_048_576) MB），無法匯入。"
        case .unreadable: return "無法讀取這個檔案，請確認檔案存在且可以開啟。"
        case .notABackup: return "這不是冰箱管理員的備份檔。"
        case .malformed: return "備份檔已損壞或格式不正確，無法匯入。"
        case let .unsupportedVersion(version):
            return "這個備份來自較新的 App 版本（格式 \(version)），請先更新冰箱管理員再匯入。"
        case .tooManyRecords: return "備份內的資料筆數超過上限，無法匯入。"
        case .noFridges: return "備份裡沒有冰箱資料，無法匯入。"
        case let .tooManyFridges(count):
            return "這個備份有 \(count) 台冰箱，但目前最多支援 \(FridgePolicy.maxRefrigerators) 台，無法匯入。為避免遺失資料，不會自動刪除多出來的冰箱。"
        case .duplicateIDs: return "備份內有重複的資料識別碼，檔案可能已損壞。"
        case let .invalidLayout(name): return "冰箱「\(name)」的隔層資料無效，檔案可能已損壞。"
        case let .invalidFood(name): return "食材「\(name)」的資料無效，檔案可能已損壞。"
        case let .invalidCompartmentReference(name): return "食材「\(name)」所在的冰箱或隔層不存在，檔案可能已損壞。"
        case .invalidPreferences: return "備份內的偏好設定無效，檔案可能已損壞。"
        case .currentDataUnreadable: return "無法讀取目前的資料，為了安全沒有進行還原。"
        case .recoverySnapshotFailed: return "無法建立還原前的保護副本（可能是儲存空間不足），沒有進行還原。"
        case .saveFailed: return "還原時儲存失敗，目前的資料沒有變更。"
        case .exportFailed: return "無法建立備份檔，請再試一次。"
        case .insufficientStorage: return "儲存空間不足，無法建立備份檔。"
        case let .restoreFailed(rolledBack):
            return rolledBack ? "還原沒有完成，已恢復成還原前的資料。" : "還原沒有完成，且無法自動恢復；還原前的保護副本已保存在 App 中。"
        }
    }
}

/// What the preview shows.
struct BackupSummary: Equatable {
    let exportedAt: Date
    let applicationVersion: String
    let fridgeNames: [String]
    let activeFoodCount: Int
    let historyCount: Int
    let favoriteFoodCount: Int
    /// Category IDs this build doesn't know (kept as-is; shown as 其他).
    let unknownCategoryCount: Int
}

/// Decodes and fully validates a backup without touching any stored data.
enum BackupValidator {
    static let maxFileSize = 20 * 1_048_576
    static let maxFoodRecords = 50_000
    static let maxFavoriteFoods = 200
    static let earliestDate = Date(timeIntervalSince1970: 0)
    static let latestDate = Date(timeIntervalSince1970: 7_258_118_400) // 2200-01-01

    private struct VersionProbe: Decodable { let formatVersion: Int? }

    static func decode(_ data: Data, maxFileSize: Int = maxFileSize) throws -> FoodManagerBackup {
        guard data.count <= maxFileSize else { throw BackupError.fileTooLarge(data.count) }
        // Check the version first, so a newer format gets a clear message instead of "malformed".
        guard let probe = try? JSONDecoder().decode(VersionProbe.self, from: data) else { throw BackupError.malformed }
        guard let version = probe.formatVersion else { throw BackupError.notABackup }
        guard version <= FoodManagerBackup.currentFormatVersion, version >= 1 else { throw BackupError.unsupportedVersion(version) }
        let backup: FoodManagerBackup
        do {
            backup = try BackupCoding.decoder().decode(FoodManagerBackup.self, from: data)
        } catch {
            throw BackupError.malformed
        }
        try validate(backup)
        return backup
    }

    static func validate(_ backup: FoodManagerBackup) throws {
        guard backup.foods.count <= maxFoodRecords, backup.preferences.favoriteFoods.count <= maxFavoriteFoods else {
            throw BackupError.tooManyRecords
        }
        guard !backup.fridges.isEmpty else { throw BackupError.noFridges }
        guard backup.fridges.count <= FridgePolicy.maxRefrigerators else { throw BackupError.tooManyFridges(backup.fridges.count) }
        guard validDate(backup.exportedAt) else { throw BackupError.malformed }

        // Identifiers must be unique across the whole file.
        let fridgeIDs = backup.fridges.map(\.id)
        let compartmentIDs = backup.fridges.flatMap { $0.allCompartments.map(\.id) }
        let foodIDs = backup.foods.map(\.id)
        let favoriteIDs = backup.preferences.favoriteFoods.map(\.id)
        for ids in [fridgeIDs, compartmentIDs, foodIDs, favoriteIDs] where Set(ids).count != ids.count {
            throw BackupError.duplicateIDs
        }
        guard Set(fridgeIDs).isDisjoint(with: compartmentIDs) else { throw BackupError.duplicateIDs }

        var ownerByCompartment: [UUID: UUID] = [:]
        for fridge in backup.fridges {
            guard (try? FridgeDirectory.validatedName(fridge.name)) == fridge.name, validDate(fridge.createdAt) else {
                throw BackupError.invalidLayout(fridge.name)
            }
            let domain = fridge.fridge
            guard FridgeLayoutEngine.validate(domain).isEmpty,
                  fridge.cabinetCompartments.allSatisfy({ $0.zone == .cabinet }),
                  fridge.doorCompartments.allSatisfy({ $0.zone == .door }) else {
                throw BackupError.invalidLayout(fridge.name)
            }
            for compartment in fridge.allCompartments { ownerByCompartment[compartment.id] = fridge.id }
        }

        let knownFridges = Set(fridgeIDs)
        for food in backup.foods {
            try validateFields(food)
            guard knownFridges.contains(food.fridgeID) else { throw BackupError.invalidCompartmentReference(food.name) }
            let owner = ownerByCompartment[food.compartmentID]
            if food.consumedAt == nil {
                // Active food must sit in an existing compartment of its own fridge.
                guard owner == food.fridgeID else { throw BackupError.invalidCompartmentReference(food.name) }
            } else if let owner, owner != food.fridgeID {
                // History may point at a deleted compartment, but never at another fridge's compartment.
                throw BackupError.invalidCompartmentReference(food.name)
            }
        }

        let preferences = backup.preferences
        let categoryIDs = preferences.favoriteCategoryIDs
        guard categoryIDs.count <= 50, Set(categoryIDs).count == categoryIDs.count,
              categoryIDs.allSatisfy({ !$0.isEmpty && $0.count <= 64 }),
              FavoriteFoods(templates: preferences.favoriteFoods).templates.count == preferences.favoriteFoods.count,
              NotificationPreferences.leadDayRange.contains(preferences.notifications.expirationLeadDays),
              (0...23).contains(preferences.notifications.reminderHour),
              (0...59).contains(preferences.notifications.reminderMinute) else {
            throw BackupError.invalidPreferences
        }
    }

    static func summary(of backup: FoodManagerBackup) -> BackupSummary {
        BackupSummary(exportedAt: backup.exportedAt, applicationVersion: backup.applicationVersion,
                      fridgeNames: backup.fridges.sorted { $0.createdAt < $1.createdAt }.map(\.name),
                      activeFoodCount: backup.foods.filter { $0.consumedAt == nil }.count,
                      historyCount: backup.foods.filter { $0.consumedAt != nil }.count,
                      favoriteFoodCount: backup.preferences.favoriteFoods.count,
                      unknownCategoryCount: backup.foods.filter { !FoodCategoryCatalog.contains($0.categoryID) }.count)
    }

    private static func validateFields(_ food: BackupFood) throws {
        let name = food.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let unit = food.unit.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= FoodValidationError.maxNameLength,
              !unit.isEmpty, unit.count <= FoodValidationError.maxUnitLength,
              !food.categoryID.isEmpty, food.categoryID.count <= 64,
              let quantity = food.decimalQuantity, quantity > 0, quantity <= 1_000_000,
              food.storageReminderDays.map(FoodValidationError.reminderDayRange.contains) ?? true,
              [food.storedAt, food.createdAt, food.updatedAt].allSatisfy(validDate),
              food.expirationDate.map(validDate) ?? true,
              food.consumedAt.map(validDate) ?? true else {
            throw BackupError.invalidFood(food.name.isEmpty ? "（未命名）" : String(food.name.prefix(30)))
        }
    }

    private static func validDate(_ date: Date) -> Bool {
        date.timeIntervalSinceReferenceDate.isFinite && date >= earliestDate && date <= latestDate
    }
}
