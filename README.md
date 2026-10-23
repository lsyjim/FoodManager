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

- **格式**：`FoodManager-Backup-YYYY-MM-DD.json`，一般可讀的 JSON（**沒有加密**，請自行保管）。`formatVersion`（目前 2；v2 加入冰箱磁鐵與照片位元組，v1 備份仍可匯入，視為沒有磁鐵）、`exportedAt`、`applicationVersion`、`backupID`，加上冰箱（含隔層、冷藏／冷凍分類、門的狀態）、所有食材（含食用紀錄）、常用分類與順序、常用食材與順序、通知設定、目前選擇的冰箱。不含 StoreKit 交易、廣告識別、小工具快照、快取與 Debug 開關。日期以原始秒數儲存、數量以文字儲存，往返不失真。程式：`FoodManager/Persistence/Backup/`。
- **匯出**：讀取全部資料 → 用匯入同一套規則驗證 → 原子寫入暫存檔並讀回確認 → 系統分享表單（檔案／iCloud 雲碟）。只有分享完成才顯示「備份已匯出」；暫存檔在分享結束後刪除。
- **匯入**：系統文件選擇器 → 先檢查大小（上限 60 MB、食材 5 萬筆、照片 150 張且每張 ≤ 4 MB）→ 版本（較新的格式會請使用者先更新 App）→ 完整驗證（必要欄位、型別、日期與數值範圍、重複 ID、冰箱數 1…`FridgePolicy.maxRefrigerators`、食材→冰箱、食材→隔層、隔層屬於同一台冰箱、版面有效）。驗證期間不會改動任何資料。超過 2 台冰箱的備份直接拒絕並說明，不會自動丟掉冰箱。不認得的分類 ID 原樣保留（顯示為「其他」），預覽會標示。
- **預覽**：備份時間、冰箱、目前食材、食用紀錄、常用食材、相容性；按「以此備份取代目前資料」並在確認對話框再按「取代並還原」才會執行。
- **還原只做完整取代，不合併**：
  1. 讀取目前資料作為保護副本（記憶體 + `Application Support/Backups/PreRestore-Backup.json`，只保留最新一份）。讀不到或寫不進去（例如空間不足）就停止，什麼都不改。
  2. 冰箱與食材在**一次** SwiftData `save()` 中取代（保留所有 ID；同 ID 就地更新、多的刪除、新的插入）。失敗時 SwiftData 回滾，資料不變。
  3. 寫入 UserDefaults 偏好（常用分類、常用食材、通知設定、選擇的冰箱）並讀回比對。
  4. 讀回全部資料與備份逐筆比對。第 3、4 步任一失敗 → 用保護副本以同樣方式寫回並再次驗證，告知使用者「已恢復成還原前的資料」（若連恢復都失敗則誠實說明，保護副本仍在）。
  5. 全部成功後，以同一個 ModelContainer 重新建立整個工作階段（新的 context，不開第二個資料庫、不刪資料庫檔），重新排程通知、重寫小工具快照並重新載入小工具，再顯示「已還原備份」。通知或小工具更新失敗時會另外說明，但不會說資料遺失。
- **原子性限制**：SwiftData 與 UserDefaults 沒有共同交易。資料庫部分是單次 save，原子；偏好是之後寫入並以回滾補償。若在兩者之間 App 被強制結束，可能出現「新食材＋舊偏好」，此時保護副本仍在 `PreRestore-Backup.json`。
- 不在本階段範圍：iCloud／CloudKit 同步、自動排程備份、CSV、合併匯入、超過 2 台冰箱。

## 冰箱磁鐵（Phase 4.3）

關門的冰箱首頁 → **裝飾冰箱**。全部免費，不上傳任何照片。

- **顯示**：磁鐵畫在關門冰箱的門上，只用來顯示（不攔截觸控），點磁鐵一樣會開門；開門時隱藏，不影響隔層與食材操作。每台冰箱各自一組磁鐵，切換冰箱就載入該冰箱的磁鐵。
- **編輯**（全螢幕，不能開門）：點一下選取、**再點一下換造型**、拖曳移動（直接拖未選取的磁鐵也會選取並移動）、雙指縮放、雙指旋轉；下方有 造型／複製／上移／下移／刪除；可互相重疊。VoiceOver 可用自訂動作換造型、移動、縮放、旋轉。
- **造型**（內建與照片都適用，依序循環）：原始形狀 → 拍立得（下方留白較多）→ 白框（方角）→ 圓角白框 → 郵票花邊 → 圓形 → 星星。換造型時寬度不變、高度依造型重算；新照片預設白框，內建圖預設原始形狀。造型存在 `MagnetRecord.styleRaw`（可為空，舊資料自動套預設）與備份的 `style` 欄位（舊備份沒有此欄位也能匯入）。
- **草稿交易**：進入時記下原本的排列；所有變更只改草稿。**儲存**：一次 SwiftData save 取代該冰箱的磁鐵，成功後才清掉沒人用的照片檔；失敗則留在編輯畫面、草稿不變、可重試。**取消**：確認後丟掉草稿，原排列完全不變，這次匯入但沒儲存的照片檔會刪除。
- **座標**：位置與大小都以「門面」為 0…1 的比例儲存（`FridgeTemplate.closedDoorRect`，從 `fridge_closed` 量測，不含外框、側邊與腳），先算出 aspect-fit 後實際的圖片範圍再換算，所以各種螢幕寬度看起來一樣。中心點限制在門面內（至少約 1/4 留在門上）；寬度 12%…90% 門寬，縮放保持圖片比例；旋轉 −π…π；非有限數值一律拒絕或修正。
- **資料**：`MagnetRecord`（SwiftData，新增實體，舊資料不需遷移）：id、fridgeID、來源（內建／照片）、builtInAssetID、localImageID、centerX/Y、width/height、rotation、zIndex、createdAt、updatedAt。照片**不存進資料庫**：`Application Support/Magnets/<id>.img`（長邊 1024 px，含透明時 PNG、否則 JPEG）＋ `<id>.thumb`（240 px）。複製磁鐵共用同一個照片檔；只有在沒有任何冰箱的磁鐵引用時才刪除。刪除冰箱時，它的磁鐵在同一次 save 中刪除，成功後才清理照片。
- **照片匯入**：系統 `PHPickerViewController`（不需要相簿權限，只拿到使用者選的那張）。用 ImageIO 直接縮圖（套用 EXIF 方向、不先解碼原圖、拒絕 > 80 MB 或超大像素的檔案），格式不支援或解碼失敗會說明原因；取消時什麼都不變。
- **效能**：手勢過程只改 transform，不重新解碼圖片、不寫資料庫；圖片有快取；陰影點陣化。
- **內建磁鐵**：圖片放在 **`FoodManager/BuiltInMagnets.bundle/`** 資料夾。新增磁鐵只要把 PNG／JPEG／HEIC／WebP 丟進這個資料夾再編譯，**不用改程式、不用動 Assets**（已驗證一般增量編譯就會帶入新增或刪除的檔案）。以檔名（不含副檔名）當 ID，所以上架後請勿改名，否則已貼上的磁鐵會找不到圖（會顯示空白卡片，不會壞）；顯示順序依檔名排序，可用 `01-`、`02-` 前綴排序。去背的透明 PNG 在「原始形狀」會保留外形。挑選畫面是一排可左右滑動的純圖片，沒有文字。目前內建：雛菊、博美狗、草地明信片、草莓餅乾（由使用者提供的範本去背製成）。
- **備份**：見上方 v2 格式。匯出時若有磁鐵照片檔遺失，會拒絕匯出並說明，不會產生缺照片的備份。

## iCloud 同步（Phase 4.4）

免費、免註冊：資料存在使用者自己 Apple 帳號的 **iCloud 私人資料庫**（`iCloud.FoodManager.HowCode`），沒有自架伺服器、沒有 Firebase／Google 登入。設定 → 資料管理 → **iCloud 自動同步**（預設開啟，可關閉）。

**架構**：SwiftData 內建的 CloudKit 鏡像（`ModelConfiguration(cloudKitDatabase: .private(...))`），沒有另外寫同步引擎。資料一律先存本機（local-first），離線、未登入、iCloud 出問題時 App 照常使用，不會改用暫存記憶體資料庫；連線後由 iOS 自動上傳。測試與 UI 測試一律 `cloudKitDatabase: .none`（加了 iCloud entitlement 後 SwiftData 預設會自動同步，所以每個 container 都明確指定）。

**模型調整（皆為輕量遷移，保留所有資料列與 ID）**：CloudKit 不支援唯一性限制，也要求每個欄位可為空或有預設值。
- `FridgeRecord`／`FoodItemRecord`／`MagnetRecord`：移除 `@Attribute(.unique)`，所有欄位加預設值。沒有 relationship（一律用 UUID 參照），不受 CloudKit 關聯規則影響。
- 新增 `MagnetImageRecord`：磁鐵照片位元組（`@Attribute(.externalStorage)`，CloudKit 以 CKAsset 存在私人資料庫，不公開）。只存 ≤1024 px 的顯示用圖，不上傳原圖；同一張照片一筆，複製磁鐵不會重複上傳。本機 `Application Support/Magnets` 改為快取，缺檔時從記錄寫回。
- 已用真實的 Phase 4.3 資料庫檔驗證（`FoodManagerTests/Fixtures/precloud-4.3.store`）：遷移後兩台冰箱、隔層、食材、紀錄、磁鐵排列與 ID 完全相同，舊的唯一索引已移除。

**同一筆資料出現多份**：CloudKit 無法保證唯一，同一個 App ID 可能出現兩列（例如兩台裝置還原同一份備份）。App **不刪除「重複」的資料列**（兩台裝置同時刪不同那份會讓資料消失），而是讀取時合併（較新的 `updatedAt` 優先，平手時用內容決定，所有裝置結果一致），寫入／刪除時套用到所有同 ID 的列（`SyncedRecords`）。

**第一次同步前的保護（不會刪除、搬移或取代資料庫）**：每台裝置第一次開啟同步前：
1. 原封不動複製資料庫檔（`Backups/Protection/PreCloud-Store/`）。
2. 在本機開啟資料庫完成輕量遷移，為既有的磁鐵照片建立同步記錄。
3. 寫出 JSON 備份 `PreCloud-Backup.json` 並讀回驗證。

任何一步失敗就不開同步、照常使用本機資料，下次再試（已測試中斷情境）。

**冰箱數量（`FridgePolicy` 仍是唯一依據，兩台免費）**：新安裝的預設冰箱使用固定 ID，兩台新裝置同步後是同一台而不是兩台。新裝置收到「比它更早建立」的冰箱時，若自己的預設冰箱從未使用（沒改名、沒改隔層、沒有食材紀錄、沒有磁鐵），就移除這台空的預設冰箱。超過 2 台（兩台裝置同步前各自建立）時不隱藏也不刪除，管理冰箱出現「需要處理 → 合併冰箱」：由使用者選擇移除哪台、移到哪台、放到哪個隔層，所有食材、紀錄與磁鐵一次搬移（同一次儲存）。

**亂序與衝突**：
- 隔層不存在的食材：沿用既有的「未放置」提示，不會自動換位置。
- 所屬冰箱還沒同步到（或已在別台刪除）的食材：顯示在「需要處理 → N 筆食材找不到所屬冰箱」，由使用者選擇放到哪裡，不會自動指派。
- 數量、名稱、隔層配置（整個配置是一筆資料）、磁鐵位置等同時修改：**以最後寫入者為準**（CloudKit 鏡像以記錄為單位）。
- 刪除與修改同時發生：通常刪除優先。若修改的資料其冰箱已刪除，會出現在「找不到所屬冰箱」。
- 吃完（consumed）是更新而不是刪除，所以紀錄不會因同步而遺失。

**照片同步**：磁鐵的資料先到、照片後到時，顯示中性的空白卡片，位置與變形保留，照片到了自動顯示，不會刪除磁鐵。照片記錄只在「這台裝置刪掉最後一個使用它的磁鐵」時才刪除，所以比磁鐵先到的照片不會被誤刪。

**偏好**：常用分類與常用食材透過 iCloud 鍵值儲存同步，每個項目以最後寫入者為準。第一台裝置上傳本機設定，之後的裝置以 iCloud 上的為準。以下設定不同步，留在每台裝置：
- 通知設定：提醒是本機通知，授權狀態也是每台裝置各自的。
- 目前選擇的冰箱。
- Debug 開關。

**帳號政策（A）**：
- 記住同步過的帳號：存 iCloud 使用者 ID 的雜湊，不存原始 ID。
- 未登入或 iCloud 不可用：不刪除本機資料，畫面說明原因與設定方式。
- 換成不同帳號：iOS 會把畫面上的資料換成新帳號的資料。App 不會把舊帳號的資料上傳到新帳號，而是提示一次「iCloud 帳號已變更」，並在 iCloud 自動同步畫面列出保護副本，由使用者自己決定是否還原；還原的資料會同步到目前帳號。
- 保護副本：每次進入背景時，依帳號各保留一份（`Account-<雜湊>.json`、未登入時為 `Local.json`），只存在本機，不會用一個帳號的資料覆蓋另一個帳號的副本。

**同步狀態**：只顯示系統實際回報的狀態（`NSPersistentCloudKitContainer` 的事件、帳號狀態、本機儲存）：iCloud 可使用、等待同步（本機有變更尚未上傳）、同步中、同步發生問題、iCloud 無法使用、已關閉。不顯示「已同步」，只顯示「最近一次完成的 iCloud 作業」的時間（取自事件結束時間）。

**收到其他裝置的變更後**：先整理資料，比對資料指紋；確定有變更時，等使用者沒在編輯或沒開著其他畫面，才用同一個 container 重建首頁。重建後會重新排程通知（識別碼固定，不會重複）並重寫小工具快照。小工具 extension 不碰資料庫。

**手動備份不受影響**：匯出、匯入、分享表單、檔案選擇器、預覽與安全還原都保留，iCloud 關閉或同步失敗時也能用。備份檔不含 Apple 帳號、CloudKit 記錄 ID 或交易資訊，可以給使用不同 Apple 帳號的人匯入，舊的 v1／v2 檔案仍可匯入。
- 磁鐵照片仍內嵌在 JSON 中。若有照片還沒從 iCloud 下載完成，匯出前會先詢問；同意後，那些磁鐵在還原時會保留位置、顯示為空白卡片，預覽也會標示。
- 開啟同步時，還原預覽會先說明：還原的內容會同步到目前的 iCloud，並取代其他開啟同步的裝置上的資料。

**發佈前**：
- 帳號：需要付費開發者帳號（已用 `-allowProvisioningUpdates` 自動註冊 container；描述檔已包含 CloudKit、Key-Value 與 Push）。
- 權限：Push 的 `aps-environment` 目前是 development，App Store 發佈時 Xcode 會自動改成 production。
- **CloudKit Console**：先在開發環境用實機跑過一次，讓 schema 建立，再按「Deploy Schema Changes to Production」。沒做這步，正式版無法同步。
- 背景模式：已開啟 `remote-notification`，讓變更能較快送達。
- 實機雙裝置驗證：模擬器沒有登入 iCloud，所以目前**尚未**實際驗證兩台裝置之間的同步，請照下方清單在兩台已登入同一 Apple 帳號的裝置上測試。

**已知限制／未來共享冰箱**：
- 目前所有資料都在私人資料庫的預設 zone。未來的「共享冰箱」需要 CloudKit Shared Database／CKShare：可能要把每台冰箱的資料移到各自的 zone，或另外設計 store 設定。
- 冰箱、食材、磁鐵都以 UUID 參照，沒有寫死「全部屬於目前使用者」的假設，搬移時不需要改 ID。
- 隔層配置是一筆 JSON，兩台裝置同時改配置時以後寫入者為準。

## 1.0 發佈準備（Phase 5）

發佈檢查、隱私揭露、後台設定、TestFlight 步驟與 GO / NO-GO 判斷見 [`docs/RELEASE-1.0.md`](docs/RELEASE-1.0.md)。1.0 為免費 App，有廣告（首頁 Banner、裝飾完成插頁、設定頁「觀看廣告」），沒有 App 內購買（`MonetizationPolicy(adsEnabled: true, purchasesEnabled: false)`）。Release archive 必須填入正式 AdMob ID（`ADMOB_APP_ID`、`ADMOB_BANNER_UNIT_ID`、`ADMOB_INTERSTITIAL_UNIT_ID`），否則「Check AdMob IDs」建置階段會讓 archive 失敗。

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
