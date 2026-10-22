import UIKit

/// App settings: 完整版, 通知 (existing notification settings), 廣告與隱私, and — in Debug builds run
/// from Xcode only — developer switches for testing free/premium and ads.
final class SettingsViewController: UITableViewController {
    private enum Row: Equatable {
        case upgrade, restore, premiumUnlocked, adFree
        case notifications, fridges
        case cloudSync, exportBackup, importBackup
        case privacyOptions
        #if DEBUG
        case devPremium, devAds, devResetConsent, devAdStatus
        #endif
    }

    private struct Section {
        let title: String
        let footer: String?
        let rows: [Row]
    }

    private let entitlements: EntitlementService?
    private let ads: AdsCoordinator?
    private let notifications: NotificationCoordinator
    private let makeFridgeManagement: (() -> UIViewController?)?
    private let backup: BackupFlow?
    private var sections: [Section] = []

    /// `entitlements` / `ads` are nil while monetization is suspended (`MonetizationPolicy`): every paid
    /// entry point (完整版, 恢復購買, 廣告與隱私, developer purchase switches) is then hidden.
    init(entitlements: EntitlementService?, ads: AdsCoordinator?, notifications: NotificationCoordinator,
         makeFridgeManagement: (() -> UIViewController?)? = nil, backup: BackupFlow? = nil) {
        self.makeFridgeManagement = makeFridgeManagement
        self.backup = backup
        self.entitlements = entitlements
        self.ads = ads
        self.notifications = notifications
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "設定"
        view.accessibilityIdentifier = "settings"
        tableView.backgroundColor = Theme.Color.background
        for name in [Notification.Name.entitlementsDidChange, .adAvailabilityDidChange, .cloudSyncStatusDidChange] {
            NotificationCenter.default.addObserver(self, selector: #selector(rebuild), name: name, object: nil)
        }
        rebuild()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(false, animated: animated)
    }

    @objc private func rebuild() {
        sections = []
        if let entitlements {
            switch entitlements.state {
            case .premium:
                sections.append(Section(title: "完整版", footer: nil, rows: [.premiumUnlocked, .adFree]))
            case .free, .unknown:
                sections.append(Section(title: "完整版", footer: "完整版為一次性購買，永久移除廣告。", rows: [.upgrade, .restore]))
            }
        }
        sections.append(Section(title: "一般", footer: nil, rows: makeFridgeManagement == nil ? [.notifications] : [.fridges, .notifications]))
        if backup != nil {
            sections.append(Section(title: "資料管理",
                                    footer: "iCloud 自動同步會在你自己的裝置之間同步資料。匯出的備份檔是一般可讀的 JSON 文字檔（含磁鐵照片），沒有加密，只會存到你選擇的位置（例如「檔案」或 iCloud 雲碟），也可以分享給使用不同 Apple 帳號的人匯入。匯入備份會取代目前所有資料。",
                                    rows: [.cloudSync, .exportBackup, .importBackup]))
        }
        if let ads, entitlements?.isPremium == false, ads.privacyOptionsRequired {
            sections.append(Section(title: "廣告與隱私", footer: "管理廣告個人化與資料使用的同意設定。", rows: [.privacyOptions]))
        }
        #if DEBUG
        if entitlements != nil {
            sections.append(Section(title: "開發者測試（只在 Xcode 執行的版本出現）",
                                    footer: "「依購買紀錄」使用 StoreKit 的實際（或 StoreKit 測試）購買狀態。這些開關不會出現在 TestFlight 與 App Store 版本。",
                                    rows: [.devPremium, .devAds, .devAdStatus, .devResetConsent]))
        }
        #endif
        tableView.reloadData()
    }

    // MARK: - Table

    override func numberOfSections(in tableView: UITableView) -> Int { sections.count }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { sections[section].rows.count }
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? { sections[section].title }
    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? { sections[section].footer }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
        cell.backgroundColor = Theme.Color.interior
        var content = cell.defaultContentConfiguration()
        content.textProperties.font = UIFont.preferredFont(forTextStyle: .body)
        content.secondaryTextProperties.font = UIFont.preferredFont(forTextStyle: .body)
        switch sections[indexPath.section].rows[indexPath.row] {
        case .upgrade:
            content.text = "升級完整版"
            content.image = UIImage(systemName: "sparkles")
            cell.accessoryType = .disclosureIndicator
            cell.accessibilityIdentifier = "settings.upgrade"
        case .restore:
            content.text = "恢復購買"
            content.image = UIImage(systemName: "arrow.clockwise")
            cell.accessibilityIdentifier = "settings.restore"
        case .premiumUnlocked:
            content.text = "已解鎖完整版"
            content.image = UIImage(systemName: "checkmark.seal")
            cell.selectionStyle = .none
        case .adFree:
            content.text = "廣告"
            content.secondaryText = "已移除"
            content.image = UIImage(systemName: "nosign")
            cell.selectionStyle = .none
        case .fridges:
            content.text = "管理冰箱"
            content.image = UIImage(systemName: "refrigerator")
            cell.accessoryType = .disclosureIndicator
        case .notifications:
            content.text = "通知設定"
            content.image = UIImage(systemName: "bell")
            cell.accessoryType = .disclosureIndicator
        case .cloudSync:
            content.text = "iCloud 自動同步"
            content.secondaryText = CloudSyncMonitor.shared.status(enabled: CloudSyncSettings.shared.isEnabled).title
            content.image = UIImage(systemName: "icloud")
            cell.accessoryType = .disclosureIndicator
            cell.accessibilityIdentifier = "settings.cloudSync"
        case .exportBackup:
            content.text = "匯出備份"
            content.image = UIImage(systemName: "square.and.arrow.up")
            cell.accessibilityIdentifier = "settings.exportBackup"
        case .importBackup:
            content.text = "匯入備份"
            content.image = UIImage(systemName: "square.and.arrow.down")
            cell.accessoryType = .disclosureIndicator
            cell.accessibilityIdentifier = "settings.importBackup"
        case .privacyOptions:
            content.text = "廣告與隱私設定"
            content.image = UIImage(systemName: "hand.raised")
            cell.accessoryType = .disclosureIndicator
        #if DEBUG
        case .devPremium:
            content.text = "版本"
            let control = UISegmentedControl(items: DeveloperOverrides.PremiumOverride.allCases.map(\.title))
            control.selectedSegmentIndex = DeveloperOverrides.PremiumOverride.allCases.firstIndex(of: DeveloperOverrides.shared.premium) ?? 0
            control.accessibilityIdentifier = "dev.premium"
            control.addAction(UIAction { [weak self, weak control] _ in
                guard let self, let control else { return }
                DeveloperOverrides.shared.premium = DeveloperOverrides.PremiumOverride.allCases[control.selectedSegmentIndex]
                self.entitlements?.developerOverridesChanged()
            }, for: .valueChanged)
            control.sizeToFit()
            cell.accessoryView = control
            cell.selectionStyle = .none
        case .devAds:
            content.text = "顯示廣告"
            let toggle = UISwitch()
            toggle.isOn = DeveloperOverrides.shared.adsEnabled
            toggle.onTintColor = Theme.Color.stroke
            toggle.accessibilityIdentifier = "dev.ads"
            toggle.addAction(UIAction { [weak self, weak toggle] _ in
                DeveloperOverrides.shared.adsEnabled = toggle?.isOn ?? true
                self?.ads?.developerSettingsChanged()
            }, for: .valueChanged)
            cell.accessoryView = toggle
            cell.selectionStyle = .none
        case .devAdStatus:
            content.text = "廣告狀態"
            content.secondaryText = adStatusText
            content.secondaryTextProperties.font = UIFont.preferredFont(forTextStyle: .footnote)
            cell.selectionStyle = .none
        case .devResetConsent:
            content.text = "重設廣告同意狀態"
        #endif
        }
        content.imageProperties.tintColor = Theme.Color.stroke
        cell.contentConfiguration = content
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch sections[indexPath.section].rows[indexPath.row] {
        case .upgrade:
            guard let entitlements else { return }
            PremiumPurchaseViewController.present(entitlements: entitlements, from: self)
        case .restore:
            restore()
        case .fridges:
            if let management = makeFridgeManagement?() { navigationController?.pushViewController(management, animated: true) }
        case .notifications:
            navigationController?.pushViewController(NotificationSettingsViewController(coordinator: notifications), animated: true)
        case .cloudSync:
            navigationController?.pushViewController(CloudSyncViewController(backup: backup), animated: true)
        case .exportBackup:
            backup?.export(from: self, sourceView: tableView.cellForRow(at: indexPath))
        case .importBackup:
            backup?.pickBackup(from: self)
        case .privacyOptions:
            guard let ads else { return }
            Task { @MainActor in await ads.presentPrivacyOptions(from: self) }
        #if DEBUG
        case .devResetConsent:
            ads?.resetConsentForTesting()
            ToastView.show("已重設，下次回到冰箱首頁時會重新詢問", in: view)
        #endif
        default:
            break
        }
    }

    #if DEBUG
    private var adStatusText: String {
        guard let ads else { return "未啟用" }
        if !ads.configuration.isComplete { return "未設定 AdMob ID" }
        let e = ads.eligibility
        var parts = [e.entitlement == .premium ? "完整版" : e.entitlement == .free ? "免費版" : "確認中"]
        parts.append(e.canRequestAds ? "已同意" : "未同意")
        parts.append(e.sdkReady ? "SDK 已啟動" : "SDK 未啟動")
        if ads.configuration.usesGoogleTestIDs { parts.append("測試廣告") }
        return parts.joined(separator: "・")
    }
    #endif

    private func restore() {
        guard let entitlements else { return }
        ToastView.show("正在恢復購買…", in: view)
        Task { @MainActor in
            let message: String
            switch await entitlements.restore() {
            case .restored: message = "已恢復完整版，廣告已移除"
            case .nothingToRestore: message = "這個 Apple ID 沒有可恢復的完整版購買紀錄"
            case let .failed(text): message = text
            }
            let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "好", style: .default))
            present(alert, animated: true)
        }
    }
}
