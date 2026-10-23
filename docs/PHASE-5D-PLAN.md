# Phase 5D 共享冰箱：架構與遷移計畫（實作前）

## 結論

1. **目前的資料模型不能直接共享。** 個人資料由 SwiftData 自動鏡像到 private DB 的 default zone。
   - CKShare 只能用在自訂 zone。
   - SwiftData 不會鏡像 shared DB。
2. **共享冰箱改用獨立管線。** 另開一個本機 store 和一個 CKSyncEngine，只管自訂 zone：主人那邊在 private DB，參與者那邊在 shared DB。
   - 個人冰箱的 SwiftData 管線完全不動。
   - 同一筆紀錄永遠不會同時由兩條管線管理。
3. **架構阻礙：CloudKit 權限是以 share 為單位，不能逐筆設定。** 同一個 share 裡的 readWrite 參與者，伺服器端可以改名稱、隔層、磁鐵。
   - 解法是每台共享冰箱拆成兩個 zone、兩個 share（見第 3 節）。
   - 若真機雙帳號驗證這個流程不成立，就停掉「主人專屬結構」這一塊，回報給你。不會用 UI 隱藏假裝有權限控管。
4. **系統版本：** 存取申請 API（`allowsAccessRequests`、`requesters`、`denyRequesters`、`blockRequesters`、`CKShareRequestAccessOperation`、`isApprovedRequester`）在 iOS 26.2 SDK 中確認存在，全部標示 `API_AVAILABLE(ios(26.0))`。部署目標維持 iOS 17。

## 1. 功能旗標（集中於 `SharingPolicy`，與 `MonetizationPolicy` 並列）

| 旗標 | Debug | Release 1.0 | 未來 |
|---|---|---|---|
| sharedRefrigeratorsEnabled | true | **false** | true |
| sharedRefrigeratorsRequirePremium | false | — | true（只限主人） |
| accessRequestsSupported | `#available(iOS 26)` | — | 同左 |

旗標關閉時的行為：
- 所有入口都隱藏。
- `windowScene(_:userDidAcceptCloudKitShareWith:)` 直接忽略邀請，不接受，也不顯示付費牆。
- CKSyncEngine 不啟動。

另外：
- 不會偽造 Premium。
- 不動廣告與 StoreKit。

## 2. 本機儲存與同步

- 新增 `Shared.store`：一個 SwiftData 容器，`cloudKitDatabase: .none`，放在 App Group。
  - 模型：SharedFridgeRecord、SharedFoodRecord、QuantityOpRecord、SharedMagnetRecord、SharedMembershipRecord。
  - 另存 CKSyncEngine 的狀態序列化。
- 兩個 CKSyncEngine：
  - private DB 的自訂 zone：主人自己的共享冰箱，也讓主人的其他裝置同步。
  - shared DB：參與中的冰箱。
- 讀取層把個人與共享冰箱合併成同一份冰箱清單。兩台冰箱上限用 `個人 + 共享（主人） + 參與` 計算。

## 3. Zone 與權限設計

每台共享冰箱拆成兩個 zone：

| Zone | 內容 | Share 權限 |
|---|---|---|
| `Fridge-<id>-Structure` | 名稱、隔層 layout、磁鐵、磁鐵照片（CKAsset）、成員顯示名稱 | 參與者 **readOnly** |
| `Fridge-<id>-Inventory` | 食材、數量操作、指向 Structure share 的 URL | 參與者 **readWrite**；`publicPermission = .none`；`allowsAccessRequests = true` |

流程：
1. 主人在 Inventory share 核准申請者（依 `participantLookupInfo`）。
2. 主人裝置用同一個身分，把對方加進 Structure share，權限 readOnly。
3. 參與者核准後才讀得到 Inventory zone，從裡面拿到 Structure share 的 URL，再自動接受。

限制如何由伺服器保證：
- 只拿到連結看不到任何資料，因為 `publicPermission = .none`，必須先通過申請與核准。
- 成員管理（移除成員、停用申請、停止共享）在 CloudKit 本來就只有主人能做。參與者只能移除自己，也就是離開。
- 參與者可以在 Inventory zone 寫入任何紀錄，這屬於食材編輯範圍，本來就允許。
  - 客戶端只從 Structure zone 讀結構，所以參與者在 Inventory 偽造的「結構」紀錄不會生效。
  - 食材指向不存在的隔層時，歸到「未放置」。

**待真機驗證的風險：** 「用申請者的 lookupInfo 把同一人加進第二個 share」以及「自動接受第二個 share」。這兩步只能用兩支 iOS 26 真機、兩個不同的 iCloud 帳號驗證。驗證失敗就依規格停止這一塊並回報。

## 4. 數量衝突

- 食材紀錄只存 `baseQuantity`。
- 每次增減是一筆 `QuantityOp`：
  - recordName = opID（UUID），重送不會重複計算。
  - 欄位：foodID、delta、時間、作者。
- 顯示數量 = `base + Σdelta`。例：5 − 1 − 2 = 2。
- 刪除食材時寫入 tombstone，晚到的 op 會被忽略。
- 主人裝置定期把舊 op 壓回 base（compaction）。

## 5. 同步頻率

- 推送通知與 CKSyncEngine 的自動排程為主。
- 只在畫面上正在顯示共享冰箱、且 App 在前景時，才額外每 30 秒 `fetchChanges` 一次。
  - 單一飛行：上一次還沒完成就略過。
  - 失敗時指數退避：30 → 60 → 120 → 300 秒。
  - 進背景就停止。

## 6. 遷移（個人冰箱 → 共享）

1. 先做本機保護副本（沿用 ProtectionSnapshots）。
2. 把冰箱寫進 `Shared.store`，上傳兩個 zone。
3. 伺服器確認成功後，才從個人 SwiftData store 刪除原紀錄。主人的其他裝置經由 private DB 的自訂 zone 收到這台冰箱。
4. 任一步失敗，個人資料保持原樣。
5. 停止共享：刪除兩個 share，冰箱留在主人的自訂 zone，成為「未共享」狀態，資料不會遺失。

既有 iCloud 資料不重設、不刪除。新的 record type 只建立在 Development 環境，**部署到 Production 由你在 CloudKit Console 手動執行**。

## 7. 狀態、成員異動與整合

- **狀態：** personalOwned / sharedOwned / sharedParticipant / pendingInvitation / unavailableOrRevoked。由 share 是否存在、`acceptanceStatus`、zone 是否消失（`zoneDeleted` / `userDeletedZone` / 權限錯誤）判斷。
- **被移除或冰箱被停止共享時：** 清掉本機 `Shared.store` 中該冰箱的資料、通知與 widget，選單顯示「共享無法存取」。
- **通知與 widget：** 每台裝置用自己有權讀到的資料各自產生。
- **備份：**
  - 匯出只含個人冰箱。
  - 破壞性還原只動個人 store，永遠不碰 `Shared.store`。

## 8. 實作分段

| 段 | 內容 | 可在模擬器驗證？ |
|---|---|---|
| 5D-1 | SharingPolicy、Shared.store、CKSyncEngine 骨架、紀錄對應、op 數量模型、單元測試 | 是（單帳號） |
| 5D-2 | 主人：轉為共享、兩個 zone 與兩個 share、Share Sheet 連結 | 部分 |
| 5D-3 | 存取申請：核准、拒絕、封鎖，成員清單、移除成員、停用申請、停止共享 | 需真機 |
| 5D-4 | 參與者：開啟連結、申請、等待、加入、離開，30 秒前景輪詢 | 需真機 |
| 5D-5 | 通知、widget、備份排除、選單標籤、規格中的 38 項測試 | 大多可 |

**不能只靠 mock 宣稱跨帳號協作成功。** 3 到 4 段需要兩支 iOS 26 裝置、兩個不同的 iCloud 帳號實測。
