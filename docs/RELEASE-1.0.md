# 冰箱管理員 1.0 — 發佈準備報告（Phase 5 / 5A）

日期：2026-10-22。Bundle ID `FoodManager.HowCode`。版本 1.0（build 1）。

## 結論：TestFlight 內部測試 GO；App Store 公開上架 NO-GO

程式面已經可以進入 TestFlight：正式 AdMob ID 已設定，Release archive 與 App Store 簽署的匯出都成功（只匯出到本機，**沒有上傳**）。還缺下列只有開發者本人能完成的事項（詳見最後的「發佈前阻擋事項」）：
- CloudKit schema 部署到 Production（正式版的 CloudKit 環境就是 Production）。
- 確認 AdMob 後台狀態（App 審核、GDPR 訊息、app-ads.txt）。
- 兩台實機的 iCloud 同步驗證。
- 隱私權政策網址與支援網址。
- 填寫 App Store Connect 的隱私問卷。

---

## 1. 建置結果

| 項目 | 結果 |
|---|---|
| Release clean build（generic iOS 實機，App + Widget） | ✅ 成功，專案程式 0 個警告（第三方套件除外） |
| 簽署與描述檔 | ✅ 自動簽署，團隊 9U53ELUVJM。描述檔含 App Group、CloudKit `iCloud.FoodManager.HowCode`、iCloud Key-Value、Push |
| Widget Extension | ✅ `FoodManager.HowCode.Widgets` 已簽署，App Group 與主程式一致 |
| Release archive | ✅ 成功（2026-10-23），打包內容只有正式 AdMob ID，沒有任何 Google 測試 ID |
| App Store 匯出（只到本機） | ✅ 成功：使用 Apple Distribution 憑證；`aps-environment` = production；CloudKit 環境 = **Production**；`get-task-allow` = 0；Widget 有自己的 App Store 描述檔 |
| 版本 | MARKETING_VERSION 1.0，CURRENT_PROJECT_VERSION 1 |
| 最低支援 | iOS 17.0，iPhone only，直式 |
| 第三方套件 | Google Mobile Ads 13.11.0、Google UMP 3.1.0（Swift Package） |
| App 圖示 | 1024×1024 RGB，無透明，為正式插畫 |
| 啟動畫面 | 系統產生（`UILaunchScreen_Generation`） |
| Debug 功能 | 開發者開關、重設同意等都在 `#if DEBUG` 內，Release 不會編入 |

## 2. 自動化測試

| 測試組 | 數量 | 結果 |
|---|---|---|
| 單元測試（FoodManagerTests） | 331 | ✅ 全部通過 |
| UI 測試（FoodManagerUITests） | 10 | ✅ 全部通過 |

本階段新增的測試：
- `AdInterstitialTests`（10 個）：第一次儲存裝飾後顯示、同一次使用不重複、30 分鐘的使用期界線、每日上限、10 分鐘冷卻、同意被拒、單元 ID 缺漏、手動廣告、不會同時兩則全螢幕廣告、只允許在指定畫面、儲存失敗或取消都不觸發。
- `ReleaseFlowUITests`（3 個）：
  - 第二台冰箱可建立、第三台會被拒、可切換冰箱。
  - 裝飾的儲存與取消、磁鐵不擋開門。
  - 資料管理三個入口都在，且沒有任何付費入口。
- 更新的測試：`MonetizationSuspensionTests` 改成 1.0 政策（有廣告、沒有購買）；廣告版位清單測試改為 1 個 Banner 加 2 個插頁。

UI 測試都用 `--uitesting`，也就是隔離的記憶體資料庫：沒有 iCloud、不寫入小工具快照、不會碰到使用者資料。

## 3. 本階段發現並修正的問題

| 嚴重度 | 問題 | 修正 |
|---|---|---|
| P1 | iPhone SE 有 Banner 時，「今日概況」被擠到設定按鈕底下（4.3 加入「裝飾冰箱」後，原本的 380pt 保留高度不夠） | 改用實際量測的高度決定 Banner：放得下時用大型自適應 Banner，空間不足改用 320×50，再不夠就不顯示；「今日概況」不會超出區域；「裝飾冰箱」在矮螢幕可以低於冰箱下緣。已在 SE、17、17 Pro Max 截圖確認 |
| P1 | 購買功能關閉時，「廣告與隱私設定」（UMP 隱私選項）永遠不會出現 | 改為只要 UMP 要求就顯示，不再依賴購買相關介面 |
| P2 | 隱私清單沒有宣告檔案時間戳 API（保護副本有用到） | 加上 `NSPrivacyAccessedAPICategoryFileTimestamp` / `C617.1` |
| P2 | 兩個編譯警告：未使用的變數，以及已淘汰的 Banner 尺寸 API | 已修正 |

## 4. 廣告（Phase 5A）

**政策**：`MonetizationPolicy.current = (adsEnabled: true, purchasesEnabled: false)`。
- 這是寫在程式裡、每次發版都會審查的常數，不是遠端或隱藏開關。改變商業模式需要新的版本並送審。
- StoreKit 程式、商品 ID 與 `.storekit` 檔都保留。交易觀察持續運作，所以既有的真實購買會照實回報；不會出現任何購買畫面。

**廣告版位**（只有這三個，`AdPlacement`）：
1. 關門首頁底部的 Banner：
   - 空間足夠時用大型自適應尺寸，不足時改用 320×50，再不夠就不顯示。
   - 載入失敗時收起並逐步延長重試間隔。
   - 一次只有一個 Banner。
2. 裝飾完成插頁：只在**第一次成功儲存**冰箱裝飾、並回到關門首頁後才顯示。
   - 取消或儲存失敗都不會觸發。
   - 每次使用期最多一次，每天最多 2 次，兩次之間至少隔 10 分鐘。
   - 廣告必須事先載好；儲存不會等待廣告，晚到的廣告也不會之後才跳出來。
   - 有其他全螢幕廣告、使用者正在操作，或同意狀態不允許時，都不顯示。
3. 設定 →「觀看廣告」（副標「手動開啟一則廣告」）：一般插頁廣告，不是獎勵廣告。
   - 沒有現成的廣告時，會載入一次（最多等候 4 秒），只在使用者仍停在設定頁時才顯示。
   - 沒有廣告可播時顯示「目前沒有可播放的廣告，請稍後再試」。
   - 不會連續自動播放，也不會同時出現兩則全螢幕廣告。

**使用期的定義**：從啟動 App 開始；只有在背景超過 30 分鐘後回來才算新的使用期。單純回到前景不會重置。
**同意**：
- 每次都先走 Google UMP，`canRequestAds` 為 false 時不會發出任何廣告請求。
- 不會要求 App Tracking Transparency（ATT），所以 App 無法取得 IDFA；這次也沒有加入任何新的追蹤。
- 廣告不會出現在啟動或離開時，也不會出現在食材編輯、隔層編輯、提醒、小工具等畫面。

**驗證結果**（Debug，使用 Google 官方測試 ID）：

| 項目 | 結果 |
|---|---|
| SDK 初始化、UMP 同意流程（目前地區不需表單） | ✅ 模擬器 |
| Banner 請求與載入（"Test mode" 廣告出現在關門首頁） | ✅ 模擬器（17、SE、17 Pro Max） |
| Banner 曝光回呼 | ⚠️ 目前沒有接 impression 回呼，只確認載入並顯示 |
| 裝飾完成插頁：請求、載入、顯示、關閉後回到首頁 | ✅ 模擬器 |
| 同一次使用第二次儲存不再顯示 | ✅ 模擬器＋單元測試 |
| 「觀看廣告」：按需載入、顯示、關閉後回到設定 | ✅ 模擬器 |
| 載入失敗、無廣告可播、同意被拒、冷卻、每日上限 | ✅ 單元測試（模擬器無法切斷網路，未做實際失敗測試） |
| 正式 App ID 與兩個廣告單元 ID | ✅ 只設定在 Release：App `ca-app-pub-3873309169448072~3121859418`、Banner `…/4487619812`、Interstitial `…/7232494815`；Debug 仍用 Google 測試 ID |
| 正式廣告實際請求、曝光與填充率 | ⛔ 需在 TestFlight 或上架後觀察 AdMob 報表；不要點擊自己的正式廣告 |
| AdMob 帳號、App 審核與 app-ads.txt 狀態 | ⛔ 我無法存取 AdMob 後台，需由你確認 |
| 實際收益 | 無法用測試廣告驗證；也未宣稱已驗證 |

## 4.1 App Store 評分

**系統評分視窗**：`ReviewRequestCoordinator` 呼叫 StoreKit 的 `AppStore.requestReview(in: UIWindowScene)`。
- 沒有自製的評分對話框，不指定星等，不會依預期評價篩選使用者，也沒有任何獎勵或功能限制。

**要求條件**（全部符合才會向 iOS 要求顯示）：
- 距離第一次啟動至少 3 天。
- 至少啟動 5 次（以 App 行程啟動計算）。
- 累計成功新增至少 5 筆食材：只算 `FoodInventoryService.add` 儲存成功的那一次，失敗、編輯、吃完、恢復都不算。
- 距離上次「要求」至少 90 天。
- 這次使用期間還沒要求過。

**時機**：只在**成功新增食材後**才評估，而且要等冰箱首頁回到穩定狀態：
- 首頁上沒有任何畫面、表單或提示，也沒在編輯隔層（所以食材編輯、裝飾冰箱、還原備份、iCloud「需要處理」流程進行時都不會出現）。
- App 在前景、有可用的 `UIWindowScene`。
- 沒有全螢幕廣告；前後 60 秒內也沒有插頁廣告（由共用的 `FullscreenPresentationGate` 控管，自動插頁廣告同樣會避開剛要求過評分的 60 秒）。
- 連續新增時編輯器還開著：每 2 秒檢查一次，最多 30 秒；超過就等下一次新增食材再評估。

**紀錄**：
- 第一次啟動時間、啟動次數、成功新增次數、上次要求時間都存在 UserDefaults，重新開啟 App 也不會重設。
- 測試與 UI 測試不會記錄，也不會要求。
- App 無從得知視窗是否真的出現或使用者給了幾顆星，所以只記錄「已要求」。

**設定 →「關於」→「到 App Store 評分」**（副標「喜歡冰箱管理員嗎？歡迎留下評價」）：
- 開啟 `https://apps.apple.com/app/id<Apple ID>?action=write-review`，不會呼叫系統評分視窗。
- Apple ID 來自建置設定 `APP_STORE_ID`（Info.plist 的 `FMAppStoreID`），**目前是空的**。
- 在 App Store Connect 建立 App 後，到「App 資訊 → Apple ID」取得那串數字填入。在那之前點擊會顯示「App Store 頁面目前還無法開啟，請稍後再試。謝謝你！」。

**StoreKit 的限制**：
- iOS 自己決定是否顯示（每個 App 一年最多 3 次，使用者也可以在系統設定關閉）。
- **TestFlight 版本不會顯示評分視窗**；Debug 版在開發中會顯示，但送出不會生效。
- 所以實際顯示只能在上架後觀察。

## 5. 資料與功能回歸

| 範圍 | 自動化測試 | 模擬器 | 實機 |
|---|---|---|---|
| 食材新增、編輯、刪除、吃完、恢復、數量（含小數）、單位、移動、搜尋、常用與最近、連續新增 | ✅ | ✅（先前各階段與本次 UI 測試） | 需驗證 |
| 冰箱：預設、改名、第 2 台、拒絕第 3 台、切換、記住選擇、門狀態、隔層編輯、複製配置、阻擋刪除 | ✅ | ✅ | 需驗證 |
| 日期與通知：到期、保存天數、跨日、月與年邊界、閏日、日光節約、時區、權限、兩台冰箱、吃完後取消、恢復後重排、序列化 | ✅（NotificationTests、FoodDateTests） | 部分 | 需驗證（真實通知送達） |
| 小工具：快照、深層連結、無效連結、選冰箱、快速新增 | ✅（WidgetIntegrationTests、WidgetLinkUITests） | ✅ 主畫面小工具顯示正常 | 需驗證（鎖定畫面小工具、隔天自動更新） |
| 磁鐵：匯入、方向、透明、縮圖、拖曳、縮放、旋轉、圖層、造型、儲存與取消、複製與刪除、冰箱隔離、重開、清理 | ✅ | ✅ | 需驗證（多張照片時的記憶體） |
| iCloud | ✅（29 個 CloudSync 測試＋真實舊資料庫遷移） | ✅ 單台模擬器遷移與狀態畫面 | ⛔ **兩台實機尚未驗證** |
| 手動備份與匯入 | ✅ | ✅ 4.2 驗收清單 | 需驗證 |

**裝置與 iOS 覆蓋**：
- 模擬器：iPhone SE（小）、iPhone 17（標準）、iPhone 17 Pro Max（大），系統都是 iOS 26.2。
- 這台 Mac 只有 iOS 26.2 runtime，所以**最低支援版本 iOS 17 尚未測試**。請在 Xcode → Settings → Components 下載 iOS 17 runtime，或用 iOS 17／18 的實機測一次。
- 顯示模式固定為淺色，方向只支援直式。

## 6. 隱私（App Store「App 隱私」填寫依據）

**App 自己的程式**：
- 不收集資料，沒有分析或追蹤 SDK，沒有自架伺服器。
- 冰箱、食材、磁鐵照片存在裝置上；開啟 iCloud 同步時存在使用者**自己的** iCloud 私人資料庫，開發者無法讀取。依 Apple 的定義，這不算開發者「收集」資料。
- 匯出的備份檔是使用者自己保存或分享的檔案，App 不會上傳。

**Google Mobile Ads 13.11.0 隱私清單宣告的收集項目**（App Store Connect 會彙整到隱私報告，**必須申報**）：

| 資料類型 | 連結到使用者 | 用於追蹤 | 用途 |
|---|---|---|---|
| 裝置 ID（Device ID） | 是 | **是**（需經 ATT 授權才能取得 IDFA） | 第三方廣告、開發者廣告、分析 |
| 廣告資料 | 是 | 否 | 第三方廣告、開發者廣告、分析 |
| 產品互動 | 是 | 否 | 分析、廣告 |
| 粗略位置 | 是 | 否 | 廣告、分析 |
| 效能資料、其他診斷資料 | 否 | 否 | 廣告、分析 |
| 當機資料 | 否 | 否 | 分析 |

UMP 也有自己的隱私清單。
- App **沒有**要求 ATT，所以 SDK 無法取得 IDFA。
- 是否在 App Store Connect 勾選「用於追蹤」，請依 Google 的「App Store 資料揭露」說明與你的 AdMob 設定自行判斷，我不代為下結論。
- 如果之後要提高廣告收益而加入 ATT，就是新增追蹤，需要另外處理。

**權限**：
- 通知：只在使用者設定提醒時才說明並請求。
- 照片：用系統的 PHPicker，不需要相簿權限。
- 不會要求相機、定位或 ATT 權限。

## 7. 你需要在後台完成的設定

**AdMob**：
1. ✅ App ID 與兩個廣告單元 ID 已提供，並只設定在 Release。
2. 確認 App 與兩個廣告單元在 AdMob 後台是啟用狀態（新的廣告單元可能需要一段時間才會開始放送）。
3. 如果要在自己的實機上用正式 ID 測試，請先在 AdMob 把那台裝置加為測試裝置，避免無效流量。
4. 在「隱私權和訊息」設定 GDPR（歐盟、英國）同意訊息；美國各州的設定依需要處理。
5. 準備開發者網站並放上 `app-ads.txt`，然後在 App Store 上架後連結 App。
6. 測試時只用測試 ID 或測試裝置，不要點擊正式廣告。

**Apple Developer / CloudKit**：
1. 用實機以 Debug 跑過所有資料類型一次，讓開發環境的 schema 建立完整。
2. 在 CloudKit Console 執行「Deploy Schema Changes…」，把 schema 部署到 Production。
3. 在兩台登入同一 Apple 帳號的裝置上，依 README「iCloud 同步」一節的步驟驗證。
4. 推播的 `aps-environment` 在 archive 或發佈時會由 Xcode 自動改成 production，不需要手動處理。

**App Store Connect 必填資料**（我不會代為編造網址或聯絡資訊）：

| 欄位 | 狀態 |
|---|---|
| App 名稱 | 冰箱管理員（是否可用需在 App Store Connect 確認） |
| 副標題、描述、關鍵字 | 需撰寫（可依 README 的功能整理） |
| 類別 | 建議：生活風格（主）、美食佳飲（次） |
| 支援網址 | ⛔ 需提供 |
| 隱私權政策網址 | ⛔ 需提供（AdMob 與 App Store 都要求） |
| App Store 的 Apple ID（數字） | ⛔ 在 App Store Connect 建立 App 後填入建置設定 `APP_STORE_ID`，「到 App Store 評分」才會啟用 |
| 年齡分級問卷 | 需填寫（App 本身沒有不當內容；含第三方廣告） |
| App 隱私 | 依第 6 節填寫 |
| 截圖 | 需要 6.9 吋（1320×2868）。請用正式 ID 設定好的 Release 候選版擷取，避免出現「Test mode」字樣 |
| 審查備註 | 見下方範本 |

**App Review 備註範本**：
> 本 App 免費，無 App 內購買。廣告：關門首頁底部橫幅；使用者第一次儲存「裝飾冰箱」後可能顯示一則插頁廣告（每次使用最多一次、每日最多兩次）；設定頁「觀看廣告」可手動開啟一則插頁廣告，沒有獎勵。不需要登入。iCloud 同步使用使用者自己的私人資料庫。審查時不需要測試帳號。

## 8. TestFlight

**狀態**：Release archive 成功，App Store 簽署的 IPA 已在本機匯出成功。**尚未上傳**，需要你明確同意。

上傳步驟：
1. App Store Connect 必須先建立這個 App（Bundle ID `FoodManager.HowCode`）。
2. 上傳：用 Xcode Organizer 選擇這次的 archive，按 Distribute App → App Store Connect；或在你同意後由我用 `xcodebuild -exportArchive`（destination: upload）上傳。
3. 處理完成後，在 TestFlight 加入內部測試人員。之後每次上傳都要把 build 號（CURRENT_PROJECT_VERSION）加 1。

**給測試人員的說明**：
- 從舊版升級：冰箱、食材、紀錄、磁鐵照片都要完整保留。
- 兩台冰箱、新增第三台時的提示、切換冰箱。
- 新增、編輯、吃完、恢復食材；提醒通知會送達，點通知會打開正確的冰箱和食材。
- 小工具：小、中、大與鎖定畫面，點擊後打開正確的畫面。
- 裝飾冰箱：照片、造型、儲存與取消；第一次儲存後可能出現一則插頁廣告。
- 設定 →「觀看廣告」。
- iCloud：兩台裝置同步、離線修改、iCloud 登出後的提示。
- 匯出與匯入備份，包括與他人分享後匯入。

## 9. 發佈前阻擋事項

| 嚴重度 | 項目 | 負責 |
|---|---|---|
| P0 | 尚未驗證 iCloud 在兩台實機之間同步，也還沒把 CloudKit schema 部署到 Production | 你（實機與 CloudKit Console） |
| ✅ | 正式 AdMob App ID、Banner 與插頁廣告 ID | 已設定在 Release，archive 已驗證 |
| P1 | AdMob 的 App 狀態、GDPR 訊息與 app-ads.txt | 你 |
| P1 | 隱私權政策網址、支援網址、App 隱私問卷（含 Google SDK 項目） | 你 |
| P2 | App Store Apple ID（`APP_STORE_ID`）：沒有設定時評分連結只會顯示提示訊息 | 建立 App 後提供給我 |
| P1 | 尚未在 iOS 17 上測試（最低支援版本） | 下載 runtime 或用實機 |
| P2 | 用實機測試通知送達、鎖定畫面小工具，以及多張照片時的記憶體 | 你（TestFlight） |
| P2 | Banner 曝光回呼沒有記錄（不影響廣告運作） | 可之後加 |
| P2 | SKAdNetwork 清單目前只有 Google 一項；加入 Google 建議的完整清單可提高 iOS 14.5+ 的廣告歸因 | 可在拿到正式 ID 時一起處理 |
| P3 | 新冰箱樣式、更多個人化、共享冰箱 | 不在 1.0 範圍 |

**GO / NO-GO**：
- **TestFlight 內部測試：GO**（需要你同意上傳）。實機與 iCloud 的驗證也要靠 TestFlight 版本完成。
- **App Store 公開上架：NO-GO**。完成上表的 P0 與 P1（兩台實機 iCloud 同步、CloudKit Production schema、AdMob 後台、隱私權政策與支援網址、App 隱私問卷、iOS 17 測試）後，重新跑完整測試與 archive，再改為 GO。
