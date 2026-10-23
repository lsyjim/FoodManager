# Phase 5E：停用個人資料自動 iCloud 同步，改為手動 iCloud 備份

## 1. 稽核結果（實作前）

### 會自動從 iCloud 帶回個人冰箱的路徑

| # | 路徑 | 行為 | 處理 |
|---|---|---|---|
| 1 | `AppPersistence.production()` → `SwiftDataFridgeStore.makeContainer(cloudKit: true)` | 只要「iCloud 自動同步」開著（預設是開），個人 SwiftData store 就用 `.private("iCloud.FoodManager.HowCode")` 開啟。NSPersistentCloudKitContainer 會持續雙向鏡像 `com.apple.coredata.cloudkit.zone`。**這是冰箱刪除後又回來的主因**：別台裝置、重新安裝、或還沒送出的刪除，都會把舊紀錄再匯入。 | 移除。個人 store 一律用 `cloudKitDatabase: .none` 開啟。 |
| 2 | `CloudSyncCoordinator` | 收到匯入通知就跑 `SyncReconciler` 並重建畫面；監看帳號變更；補上傳磁鐵照片紀錄；在背景寫入輪替保護副本。 | 移除。 |
| 3 | `PreferenceCloudSync`（iCloud Key-Value） | 自動同步常用食材與常用分類。 | 移除。偏好改為只存在本機，並包含在備份裡。 |
| 4 | `CloudSyncPreparation`、`CloudSyncMonitor`、`CloudSyncViewController` | 開啟同步前的準備、同步狀態顯示，以及「iCloud 自動同步」開關。 | 移除，改為「iCloud 備份」頁面。 |
| 5 | `SharedSyncEngine` 的 private scope | 主人的共享冰箱放在自訂 zone，會自動同步（這是設計如此）。失敗的共享嘗試留下的殘留，曾經會被抓回來（已在 211b56b 修正）。 | 保留，這屬於共享資料。刪除停止共享的冰箱時，會一併刪除它的 zone。 |

### 遷移風險與驗證

- 舊 store 是用 CloudKit 鏡像開啟的。改成 `.none` 重新開啟後：
  - 資料完整，而且可以寫入。用 `MirrorMigrationProbeTests` 實測過：先以鏡像模式建立 store，再以本機模式開啟、改名、重開，結果都正確。
  - 不需要搬移或重建檔案：檔案位置不變（App Group 的 `default.store`），所有 ID 都不變。
- 雲端上舊的鏡像資料**不會被刪除**，只是不再讀取。
- 遷移前會寫一份經過驗證的本機保護副本 `BeforeLocalOnly-Backup.json`。
- 第一次啟動新版時：
  - 若 store 已有資料（既有使用者），直接標記為「已完成首次設定」，不會跳出還原提示。
  - 若 store 是空的，才視為全新安裝。

## 2. 設計

- **個人資料**：SwiftData，只存在本機。不會自動上傳、下載或合併。
- **手動 iCloud 備份**：
  - 存放在使用者 private DB 的自訂 zone `PersonalBackups`，每份備份是一筆 `PersonalBackup` 紀錄。
  - 備份內容是現有格式的 JSON 備份檔（含磁鐵照片），以 CKAsset 上傳。紀錄本身另存統計資訊和 SHA-256 雜湊值。
  - 每份備份只寫一次、一次寫完：上傳的是一筆全新紀錄，存檔是原子操作，所以中途中斷就等於沒有這份備份。
  - 上傳後會重新下載這份備份，核對 SHA-256 才算成功。成功之後才刪除超過 3 份的舊備份。舊備份在新備份確認前一律不動。
  - 列出備份版本時只讀統計資訊（`recordZoneChanges` 搭配 `desiredKeys`，不下載內容），所以不需要在 CloudKit 設定查詢索引。
- **手動還原**：
  1. 選擇版本，下載後核對 SHA-256，再用 `BackupValidator` 驗證內容。
  2. 進入既有的預覽畫面：確認、可選擇先匯出目前資料、整批取代，失敗會自動回復。
  3. 還原後重建通知與 widget。
  4. 共享冰箱不會被還原，也不會被覆蓋（沿用 5D-5 的規則）。
- **首次啟動**：只有在本機 store 全新而且還沒做過選擇時，才查詢 iCloud 備份的清單，不下載內容。
  - 有找到備份，就詢問「從 iCloud 還原／建立新的冰箱」，並記住使用者的選擇。
  - 查不到（沒有帳號或沒有網路），就保持「待決定」，使用者可以照常使用，之後到設定手動還原。
- **共享冰箱**：維持自動同步。它們不屬於個人備份，也不會因為還原而受影響。

## 3. 完成報告

1. **冰箱刪不掉的根本原因：** 個人 store 以前一直用 CloudKit 自動鏡像（預設開啟）。只要 iCloud 上還有舊紀錄，就會被匯入回來。另一個來源是共享失敗後殘留在自訂 zone 的資料，已在 211b56b 修正。
2. **設定變更：**
   - `SwiftDataFridgeStore.makeContainer` 永遠用 `cloudKitDatabase: .none`，不再有 cloudKit 參數。
   - `AppPersistence.production()` 只開本機 store。
   - 移除 `CloudSyncCoordinator`、`CloudSyncMonitor`、`PreferenceCloudSync`、`CloudSyncPreparation`、`CloudSyncViewController`。
   - iCloud capability 保留，手動備份與共享冰箱都需要它。
3. **遷移方式：** 不搬檔、不重建，同一個檔案改成本機模式開啟。第一次啟動新版時，會寫一份經過驗證的 `BeforeLocalOnly-Backup.json`；如果寫入失敗，下次啟動會再試。
4. **資料保留：** 所有 ID、歷史紀錄、磁鐵、照片、偏好都保留。
   - 自動測試：先用鏡像模式建立 store，再改本機開啟，資料都在、可寫入、重開後仍在。
   - 模擬器實測：既有資料（7 項食材、照片磁鐵）完整，保護副本已建立。
5. **iCloud 備份格式：** 每份備份是一筆 `PersonalBackup` 紀錄，放在 `PersonalBackups` zone，包含統計欄位、SHA-256，以及以 CKAsset 上傳的既有 JSON 備份檔。
6. **版本管理：** 上傳後重新下載並核對 SHA-256，通過才算成功，成功後才刪掉超過 3 份的舊版。上傳中斷或檢查失敗時，舊版本都不受影響。
7. **還原：** 選版本 → 下載 → 核對 SHA-256 並驗證內容 → 預覽 → 確認（可先匯出目前資料）→ 整批取代，失敗會回滾 → 重建通知與 widget。
8. **首次安裝：** 只有本機 store 全新時才查詢備份清單，不下載內容。
   - 有找到備份，就詢問「從 iCloud 還原／建立新的冰箱」，並記住選擇。
   - 查不到（沒有帳號或網路），就保持待決定，之後可在設定裡還原。
9. **共享冰箱：** 維持 CKSyncEngine 自動同步，不會被備份或還原。
10. **JSON 備份：** 匯出、匯入、預覽、驗證、舊格式相容都保留。匯入不會上傳到 iCloud。
11. **磁鐵照片：** 隨 JSON 一起備份。測試確認從 iCloud 還原後照片位元組一致。
12. **測試：** 415 個單元測試、10 個 UI 測試全部通過，Release 能編譯。新增 `LocalOnlyBackupTests` 共 14 項。
    - 移除 9 項只驗證「已刪除的自動同步」的舊測試，例如帳號切換、KVS 同步、同步前準備。
13. **實際 CloudKit 驗證：** 模擬器沒有登入 iCloud，只驗證到「未登入」時的錯誤提示。真正的上傳、版本清單、還原，以及首次安裝的提示，都需要在已登入 iCloud 的真機上測。
14. **剩餘事項：**
    - 新 record type `PersonalBackup` 在 Development 第一次上傳時會自動建立。上架前要在 CloudKit Console 部署到 Production，需要你手動操作。
    - 換了 iCloud 帳號後備份會上傳到新帳號：每次備份都需要你確認，但不會特別提醒帳號已更換。
15. **刪除冰箱的問題：** 從程式路徑上已經解決：個人資料不再有任何自動下載路徑。自動測試「刪除後多次重開」通過。還差規格第 18 節的真機回歸測試：舊版同步後升級、刪除、重開、切換網路、放置一段時間。
