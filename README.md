# 冰箱管理員（FoodManager）

以手繪風冰箱為主畫面的 iPhone 食材管理 App：自由配置冷藏／冷凍隔層、記錄食材、追蹤存放天數與到期日，並以 App 內提醒中心與本地通知提醒你。

- Bundle ID：`FoodManager.HowCode`
- 語言／框架：Swift 5、UIKit（全程式碼建構，無 Storyboard、無 SwiftUI 主畫面）
- 資料：SwiftData，本機儲存，無登入、無網路需求
- 最低版本：iOS 17.0（iPhone，直向）

## 開發環境

- Xcode 26.3（以此版本建置與測試）
- iOS 26.2 模擬器（iPhone 17、iPhone 16e、iPhone SE 第 3 代 已驗證）
- 第三方套件：Google Mobile Ads SDK、Google User Messaging Platform（Swift Package Manager，只用於主 App 的廣告）

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
| `App/` | 啟動流程（`SceneDelegate`）、通知協調（`NotificationCoordinator`）、通知與小工具連結導向（`AppNotificationRouter`）、小工具快照發佈（`WidgetSnapshotPublisher`） |
| `Domain/` | 純邏輯：冰箱／隔層／食材模型、分類、日期與提醒計算、Dashboard 統計、提醒中心、通知排程規則 |
| `Layout/` | 隔層版面引擎、編輯交易（工作副本）、損壞版面修復 |
| `Persistence/` | SwiftData 模型與存取（`FridgeStore`、`FoodStore`）、儲存可用性（`AppPersistence`） |
| `UI/` | UIKit 畫面與元件 |
| `Shared/` | App 與小工具共用：提醒規則、日期與文字格式、小工具快照、Deep Link、共用圖片（分類插圖、冰箱圖） |
| `FoodManagerWidgets/` | WidgetKit 小工具（只有這裡使用 SwiftUI） |
| `Config/` | Info.plist 補充（URL scheme）、App Group entitlements |

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

## 小工具（WidgetKit）

- **我的冰箱**：小（需要注意的總數，點擊開啟提醒中心）、中（冷藏／冷凍提醒數、最緊急的一項、新增按鈕）、大（依已過期／即將到期／保存提醒分組，最多 5 項）、鎖定畫面圓形與長方形。
- **快速新增**：小與鎖定畫面圓形，點擊直接開啟 App 原本的新增食材畫面（自動帶入上次使用、仍存在的隔層；數量 1、今天、不帶到期日與保存提醒）。
- 小尺寸小工具只能有一個點擊目標（iOS 17 限制），所以新增功能放在獨立的「快速新增」小工具，而不是做一個假的按鈕。
- **資料**：App 只在資料成功儲存或讀取後，於背景執行緒把精簡快照（`widget-snapshot.json`，原子寫入）寫到 App Group `group.FoodManager.HowCode`；只包含會產生提醒的食材的名稱、位置、日期等必要欄位，不含完整資料庫。小工具只讀這個檔案，絕不寫入 App 的資料庫。內容有變才請 WidgetKit 重新整理。
- 小工具的時間軸每天午夜各有一筆，用與 App 相同的規則重新計算，所以即使一週沒打開 App，「即將到期／已過期」也會隨日期更新（實際刷新時間由 WidgetKit 決定）。
- 測試與 `--uitesting` 使用的暫存資料庫不會寫入小工具快照。

### Deep Link

`foodmanager://home`、`foodmanager://add[?compartment=]`、`foodmanager://reminders[?storage=all|refrigerated|frozen&kind=all|expiringSoon|expired|storage]`、`foodmanager://food?id=`，皆可加 `fridge=`。格式錯誤、找不到的冰箱或食材會回到冰箱首頁並顯示提示；正在編輯食材或隔層時不會被打斷。

### 實機安裝前

模擬器可直接執行。裝到實機前需在 Xcode 的 Signing & Capabilities 選擇你的 Team，並讓 App 與 `FoodManager.HowCode.Widgets` 兩個 target 都啟用同一個 App Group（`group.FoodManager.HowCode`），Xcode 會在你的開發者帳號註冊它。

## 兩台冰箱（Phase 4.1）

- 每位使用者最多 **2 台冰箱，全部免費**（上限集中在 `FridgePolicy.maxRefrigerators`）。第一次使用自動建立「我的冰箱」；舊版資料沿用原本的冰箱、隔層與食材 ID，不需要資料庫遷移。
- 首頁標題「目前使用的冰箱 ／ 冰箱名稱 ▾」：切換冰箱、新增冰箱（可用預設隔層或複製目前隔層，只複製結構、不複製食材、隔層 ID 全部重新產生）、管理冰箱。已有 2 台時「新增冰箱」會停用並顯示「目前最多可建立 2 台冰箱。」。
- 切換時整個首頁以該冰箱重建：各自的隔層、門的開關狀態、食材、今日概況互不影響；選擇的冰箱會記住到下次開啟。
- **管理冰箱**（設定或標題選單）：重新命名、切換、刪除。冰箱內還有食材時不能刪除（請先在食材列表左滑「移動」到另一台冰箱，或標記為已食用）；刪除時食用紀錄移到剩下的冰箱保留（放回冰箱時會要求選擇隔層）；不能刪除最後一台。
- 食材一律只屬於一台冰箱；跨冰箱移動時 `fridgeID` 與 `compartmentID` 一次寫入，並驗證隔層屬於目的冰箱。
- 提醒中心可切換「目前冰箱／所有冰箱」，所有冰箱時每項都標示冰箱名稱。通知同時涵蓋兩台冰箱，點通知會切到正確的冰箱。
- 小工具：App Group 檔案改為每台冰箱各一份快照（v2）。小工具長按「編輯小工具」可選擇冰箱；不選則跟隨 App 目前的冰箱；選的冰箱被刪除時自動改顯示目前冰箱。連結都帶冰箱 ID，App 會先切換再開啟。

## 備份與還原（Phase 4.2）

設定 → **資料管理** → 匯出備份／匯入備份。全部在裝置上完成，不上傳、不做分析、不記錄檔案內容。

- **格式**：`FoodManager-Backup-YYYY-MM-DD.json`，一般可讀的 JSON（**沒有加密**，請自行保管）。`formatVersion`（目前 1）、`exportedAt`、`applicationVersion`、`backupID`，加上冰箱（含隔層、冷藏／冷凍分類、門的狀態）、所有食材（含食用紀錄）、常用分類與順序、常用食材與順序、通知設定、目前選擇的冰箱。不含 StoreKit 交易、廣告識別、小工具快照、快取與 Debug 開關。日期以原始秒數儲存、數量以文字儲存，往返不失真。程式：`FoodManager/Persistence/Backup/`。
- **匯出**：讀取全部資料 → 用匯入同一套規則驗證 → 原子寫入暫存檔並讀回確認 → 系統分享表單（檔案／iCloud 雲碟）。只有分享完成才顯示「備份已匯出」；暫存檔在分享結束後刪除。
- **匯入**：系統文件選擇器 → 先檢查大小（上限 20 MB、食材 5 萬筆）→ 版本（較新的格式會請使用者先更新 App）→ 完整驗證（必要欄位、型別、日期與數值範圍、重複 ID、冰箱數 1…`FridgePolicy.maxRefrigerators`、食材→冰箱、食材→隔層、隔層屬於同一台冰箱、版面有效）。驗證期間不會改動任何資料。超過 2 台冰箱的備份直接拒絕並說明，不會自動丟掉冰箱。不認得的分類 ID 原樣保留（顯示為「其他」），預覽會標示。
- **預覽**：備份時間、冰箱、目前食材、食用紀錄、常用食材、相容性；按「以此備份取代目前資料」並在確認對話框再按「取代並還原」才會執行。
- **還原只做完整取代，不合併**：
  1. 讀取目前資料作為保護副本（記憶體 + `Application Support/Backups/PreRestore-Backup.json`，只保留最新一份）。讀不到或寫不進去（例如空間不足）就停止，什麼都不改。
  2. 冰箱與食材在**一次** SwiftData `save()` 中取代（保留所有 ID；同 ID 就地更新、多的刪除、新的插入）。失敗時 SwiftData 回滾，資料不變。
  3. 寫入 UserDefaults 偏好（常用分類、常用食材、通知設定、選擇的冰箱）並讀回比對。
  4. 讀回全部資料與備份逐筆比對。第 3、4 步任一失敗 → 用保護副本以同樣方式寫回並再次驗證，告知使用者「已恢復成還原前的資料」（若連恢復都失敗則誠實說明，保護副本仍在）。
  5. 全部成功後，以同一個 ModelContainer 重新建立整個工作階段（新的 context，不開第二個資料庫、不刪資料庫檔），重新排程通知、重寫小工具快照並重新載入小工具，再顯示「已還原備份」。通知或小工具更新失敗時會另外說明，但不會說資料遺失。
- **原子性限制**：SwiftData 與 UserDefaults 沒有共同交易。資料庫部分是單次 save，原子；偏好是之後寫入並以回滾補償。若在兩者之間 App 被強制結束，可能出現「新食材＋舊偏好」，此時保護副本仍在 `PreRestore-Backup.json`。
- 不在本階段範圍：iCloud／CloudKit 同步、自動排程備份、CSV、合併匯入、超過 2 台冰箱。

## 完整版與廣告（Phase 4，目前暫停）

> **Phase 4.1 起暫停所有付費功能**：`MonetizationPolicy.current.isEnabled = false`。不顯示購買畫面、升級／恢復購買、完整版狀態與開發者付費開關；不啟動廣告 SDK、不請求廣告。StoreKit 程式、產品 ID、`.storekit` 設定檔與使用者既有交易都保留（仍持續監聽與完成交易，不會假造完整版）。日後把這個值改回 `true` 即恢復以下 Phase 4 行為。



| 免費版 | 完整版（一次性購買，非訂閱） |
|---|---|
| 所有現有功能、食材數量不限、小工具 | 免費版全部功能 + 永久移除廣告 |
| 關門首頁一個橫幅廣告 | 無廣告 |

- **權限架構**：`EntitlementService` 是唯一判斷完整版的地方，只依 StoreKit 2 已驗證、未撤銷的 `Transaction.currentEntitlements`（離線也可用），從不以 UserDefaults 當作購買證明。功能以 `PremiumFeature` 檢查：`removeAds` 已生效；`multipleRefrigerators`、`advancedFridgeTemplates` 已定義但尚未實作，永遠不會啟用。
- **StoreKit 2**：非消耗型商品 `FoodManager.HowCode.premium`（暫定，需與 App Store Connect 一致）。價格一律來自 StoreKit；處理購買成功、取消、待核准（Ask to Buy）、失敗、未驗證、退款／撤銷、恢復購買；啟動與回到前景時重新檢查。
- **廣告**：Google Mobile Ads SDK 13 + UMP 3（Swift Package，只連結主 App，小工具不含任何廣告程式碼）。唯一版位是**關門首頁的錨定自適應橫幅**，放在底部按鈕上方；開門、編輯、新增／編輯食材、提醒中心、食用紀錄、設定、購買畫面、小工具都沒有廣告。
  - 只有在：確認為免費版 → UMP 同意流程允許請求廣告 → SDK 已啟動 → 版面放得下時才請求。完整版使用者完全不會啟動廣告 SDK。
  - 載入前與載入失敗都不佔空間；失敗後以 30 秒起倍增（最長 10 分鐘）重試；購買完整版後立即移除並釋放廣告。
- **同意與隱私**：UMP 在需要的地區（如歐盟、英國）顯示同意訊息；需要時設定頁出現「廣告與隱私設定」。**未使用 App Tracking Transparency**（不讀取 IDFA、不顯示 ATT 提示）。App 本身的 `PrivacyInfo.xcprivacy` 只宣告 UserDefaults（CA92.1）；Google SDK 內附自己的隱私清單。
- **設定**（首頁齒輪）：完整版／恢復購買、通知設定、廣告與隱私設定。

### 用 Xcode 執行的測試版開關

在 Xcode 以 Debug 執行（直接 ⌘R 到手機或模擬器）時，設定頁最下方有「開發者測試」：

- **版本**：依購買紀錄／免費版／完整版（只改畫面上的狀態，不會產生購買）。
- **顯示廣告**：開關廣告。
- **廣告狀態**、**重設廣告同意狀態**（下次回到首頁重新跑 UMP 流程）。

這些開關在 Release（TestFlight、App Store）版本中完全不存在。Debug 版也會使用 `Config/FoodManager.storekit` 做本機 StoreKit 測試購買（Xcode 的 Run 會自動帶入；在 Xcode 的 Debug → StoreKit → Manage Transactions 可清除或退款）。

### AdMob 設定（上架前必做）

目前 `ADMOB_APP_ID`、`ADMOB_BANNER_UNIT_ID`（Build Settings，App target）在 Debug 與 Release 都是 **Google 官方測試 ID**。Release 版偵測到測試 ID 時會完全不顯示廣告，避免把測試廣告給真實使用者。上架前：

1. 在 AdMob 建立 iOS App 與一個「橫幅」廣告單元。
2. 把 Release 的 `ADMOB_APP_ID`、`ADMOB_BANNER_UNIT_ID` 改成正式 ID（Debug 保留測試 ID）。
3. 在 AdMob「隱私權與訊息」建立 GDPR（以及需要的美國州別）訊息，UMP 才會在對應地區顯示。
4. `Config/FoodManager-Info.plist` 的 `SKAdNetworkItems` 目前只有 Google 的項目，請依 Google 文件補上完整清單。
5. 在 App 網站放 `app-ads.txt`。

### App Store Connect（上架前必做）

1. 建立非消耗型 App 內購買項目，產品 ID `FoodManager.HowCode.premium`（若改 ID，同步修改 `StoreProducts.premium` 與 `.storekit`），設定價格、中文名稱「冰箱管理員完整版」與說明、審查截圖。
2. 接受付費 App 協議並完成稅務與銀行資料。
3. **App 隱私問卷**：因為使用 Google Mobile Ads，需申報廣告 SDK 收集的資料（如裝置 ID、產品互動、廣告資料、粗略位置、診斷等，以 Google 的說明為準），用途包含「第三方廣告」。不可填寫「不收集任何資料」。
4. 用沙盒帳號或 TestFlight 實測購買與恢復購買。

## 圖片素材

- `FoodManager/Assets.xcassets/fridge_open_flat`：開門冰箱插圖（可編輯區位置寫在 `FridgeTemplate.swift`，更換圖片時需重新量測）。
- `Shared/SharedAssets.xcassets/fridge_closed`：關門冰箱插圖（App 與小工具共用）。
- `Shared/SharedAssets.xcassets/FoodCategories/category_*`：20 個分類插圖（App 與小工具共用），透明背景正方形 PNG；缺圖時 App 顯示文字佔位圖。

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
