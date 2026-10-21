# 冰箱管理員（FoodManager）

以手繪風冰箱為主畫面的 iPhone 食材管理 App：自由配置冷藏／冷凍隔層、記錄食材、追蹤存放天數與到期日，並以 App 內提醒中心與本地通知提醒你。

- Bundle ID：`FoodManager.HowCode`
- 語言／框架：Swift 5、UIKit（全程式碼建構，無 Storyboard、無 SwiftUI 主畫面）
- 資料：SwiftData，本機儲存，無登入、無網路需求
- 最低版本：iOS 17.0（iPhone，直向）

## 開發環境

- Xcode 26.3（以此版本建置與測試）
- iOS 26.2 模擬器（iPhone 17、iPhone 16e、iPhone SE 第 3 代 已驗證）
- 無第三方套件

## 建置

```bash
open FoodManager.xcodeproj
```

或命令列：

```bash
xcodebuild -project FoodManager.xcodeproj -scheme FoodManager -destination 'platform=iOS Simulator,name=iPhone 17' build
```

## 測試

```bash
# 單元測試
xcodebuild -project FoodManager.xcodeproj -scheme FoodManager -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:FoodManagerTests

# UI 測試（以 --uitesting 啟動，使用隔離的記憶體資料庫，不會碰到真實資料）
xcodebuild -project FoodManager.xcodeproj -scheme FoodManager -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:FoodManagerUITests
```

單元測試不需要真的取得通知權限（以測試替身取代 `UNUserNotificationCenter`）。

## 架構

| 資料夾 | 內容 |
|---|---|
| `App/` | 啟動流程（`SceneDelegate`）、通知協調（`NotificationCoordinator`）、通知點擊導向（`AppNotificationRouter`） |
| `Domain/` | 純邏輯：冰箱／隔層／食材模型、分類、日期與提醒計算、Dashboard 統計、提醒中心、通知排程規則 |
| `Layout/` | 隔層版面引擎、編輯交易（工作副本）、損壞版面修復 |
| `Persistence/` | SwiftData 模型與存取（`FridgeStore`、`FoodStore`）、儲存可用性（`AppPersistence`） |
| `UI/` | UIKit 畫面與元件 |

重點原則：

- 冷藏／冷凍分類只存在隔層上：**食材 → 隔層 → 儲存類型**，食材本身不重複儲存。
- 提醒中心、Dashboard、通知都使用同一套規則（`FoodReminderEvaluator` / `FoodDateCalculator`），以日曆天計算並尊重使用者時區。
- 版面編輯在隔離的工作副本上進行，儲存時驗證並一次寫入；取消即還原。

## 資料儲存與復原

- 冰箱版面以版本化 JSON 存於 `FridgeRecord`（目前 v2，可讀 v1），食材存於 `FoodItemRecord`；新增資料表為非破壞式遷移。
- **儲存空間無法開啟時**：顯示「暫時無法存取冰箱資料」與「重試」，此時無法新增或修改任何資料；不會改用暫存記憶體，也不會刪除或重建資料庫。只有單元測試與 `--uitesting` 會明確使用記憶體資料庫。
- **食材讀取失敗**：顯示錯誤與重試，不會被當成「冰箱是空的」，畫面上已有的資料也不會被清空。
- **操作失敗**（新增、編輯、移動、已食用、刪除）：畫面不關閉、保留輸入、顯示可行動的錯誤訊息，不會假裝成功。
- **版面資料損壞**：
  - 可解析但無效 → 在記憶體中修復，保留所有隔層 ID、名稱與冷藏／冷凍設定（食材仍在原隔層）。
  - 無法解析 → 顯示預設隔層，ID 由冰箱 ID 推導，每次啟動都相同。
  - 兩種情況都不會自動覆寫原始資料，需使用者確認；找不到原隔層的食材會列在「需要重新放置」，由使用者手動指定，不會自動搬移。

## 提醒與通知

- **提醒中心**（主畫面鈴鐺、或點 Dashboard 的即將到期／已過期／保存提醒）：可依 全部／冷藏／冷凍 與提醒類型篩選；每項食材只出現一次並列出所有狀態；依緊急程度排序。不需通知權限也能使用。
- **即將到期**：到期日在今天到 3 天後（含）；**已過期**：到期日早於今天；沒有到期日就不提醒。
- **保存提醒**：依每項食材自行設定的天數，與到期日互不影響。
- **本地通知**（`UserNotifications`）：
  - 權限不會在首次啟動就要求；在你第一次為食材設定到期日或保存提醒後才說明並詢問。被拒絕時，通知設定頁會引導到 iOS 設定。
  - 預設每日 09:00（可調整）；到期通知預設提前 1 天（0–7 天可調）；到期與保存通知可分別關閉。
  - 使用日曆觸發（不是固定 24 小時），夏令時間切換仍在當地設定時間送出；不會排程過去的時間。已過期或已超過保存天數的食材不另發通知，請在提醒中心查看。
  - 每項食材每種類型一個固定識別碼（不會重複），最多同時排 60 則（iOS 上限 64），以最近的優先。
  - 新增、編輯、移動、已食用、刪除、修改設定、回到 App 時都會重新同步；點通知會直接開啟該食材，若已食用或刪除則顯示提示。

## 圖片素材

- `Assets.xcassets/fridge_closed`、`fridge_open_flat`：冰箱插圖（開門圖的可編輯區位置寫在 `FridgeTemplate.swift`，更換圖片時需重新量測）。
- `Assets.xcassets/FoodCategories/category_*`：20 個分類插圖，透明背景正方形 PNG；缺圖時自動顯示文字佔位圖。

## 已知限制

- 冰箱插圖解析度偏低，開門圖的門板有約 2° 透視變形。
- 冰箱上的隔層文字為固定字級（空間有限）；列表、提醒中心等畫面支援動態字級。
- 通知最多同時排程 60 則；超過時以最近的優先，其餘會在之後重新同步時補上。
- 「已食用」紀錄保留在資料庫中，但目前沒有歷史紀錄畫面。

## CI（建議，尚未啟用）

GitHub Actions 的 macOS runner 需具備 Xcode 26 與 iOS 26 模擬器才能執行。可用的最小設定如下，加入前請先確認 runner 映像版本：

```yaml
name: CI
on: [push, pull_request]
jobs:
  test:
    runs-on: macos-26
    steps:
      - uses: actions/checkout@v4
      - run: xcodebuild -project FoodManager.xcodeproj -scheme FoodManager -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:FoodManagerTests
```
