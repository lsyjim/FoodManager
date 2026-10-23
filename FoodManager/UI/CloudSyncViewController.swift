import UIKit

/// 設定 → 資料管理 → iCloud 自動同步: the switch, the honest status, account guidance and the local protection
/// copies (restorable through the normal backup preview).
final class CloudSyncViewController: UITableViewController {
    private enum Row {
        case toggle, status, openSettings, snapshot(ProtectionSnapshots.Snapshot), noSnapshots
    }

    private let settings: CloudSyncSettings
    private let monitor: CloudSyncMonitor
    private let snapshots: ProtectionSnapshots
    private let backup: BackupFlow?
    private var sections: [(title: String?, footer: String?, rows: [Row])] = []

    init(settings: CloudSyncSettings = .shared, monitor: CloudSyncMonitor = .shared, snapshots: ProtectionSnapshots = .shared,
         backup: BackupFlow?) {
        self.settings = settings
        self.monitor = monitor
        self.snapshots = snapshots
        self.backup = backup
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "iCloud 自動同步"
        view.accessibilityIdentifier = "cloudSync"
        tableView.backgroundColor = Theme.Color.background
        NotificationCenter.default.addObserver(self, selector: #selector(rebuild), name: .cloudSyncStatusDidChange, object: nil)
        rebuild()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        rebuild()
    }

    var status: CloudSyncStatus { monitor.status(enabled: settings.isEnabled) }

    @objc private func rebuild() {
        let status = self.status
        var main: [Row] = [.toggle]
        if settings.isEnabled { main.append(.status) }
        if case .unavailable = status { main.append(.openSettings) }
        sections = [(nil, "資料存在你自己 Apple 帳號的 iCloud 私人資料庫，不需要另外註冊帳號，也不會公開。同步的時間由 iOS 與網路狀況決定，可能需要幾秒到幾分鐘；離線時一切照常使用，連線後會自動上傳。通知提醒在每台裝置各自設定。", main)]
        let copies = snapshots.list()
        sections.append(("保護副本（只存在這台裝置）",
                         "開啟同步前與每次離開 App 時，會在這台裝置保留一份資料副本，iCloud 登出或更換帳號後可從這裡還原。還原會取代目前的資料，開啟同步時也會同步到目前的 iCloud 帳號。",
                         copies.isEmpty ? [.noSnapshots] : copies.map(Row.snapshot)))
        tableView.reloadData()
    }

    override func numberOfSections(in tableView: UITableView) -> Int { sections.count }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { sections[section].rows.count }
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? { sections[section].title }
    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? { sections[section].footer }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.backgroundColor = Theme.Color.interior
        var content = cell.defaultContentConfiguration()
        content.textProperties.font = UIFont.preferredFont(forTextStyle: .body)
        content.secondaryTextProperties.font = UIFont.preferredFont(forTextStyle: .footnote)
        content.secondaryTextProperties.color = Theme.Color.textSecondary
        content.imageProperties.tintColor = Theme.Color.stroke
        switch sections[indexPath.section].rows[indexPath.row] {
        case .toggle:
            content.text = "iCloud 自動同步"
            content.image = UIImage(systemName: "icloud")
            let toggle = UISwitch()
            toggle.isOn = settings.isEnabled
            toggle.onTintColor = Theme.Color.stroke
            toggle.accessibilityIdentifier = "cloudSync.toggle"
            toggle.addAction(UIAction { [weak self, weak toggle] _ in
                guard let self, let toggle else { return }
                self.confirmToggle(toggle.isOn, toggle: toggle)
            }, for: .valueChanged)
            cell.accessoryView = toggle
            cell.selectionStyle = .none
        case .status:
            let status = self.status
            content.text = status.title
            content.secondaryText = [status.detail, lastSuccessText].compactMap { $0 }.joined(separator: "\n")
            content.image = UIImage(systemName: symbol(for: status))
            cell.selectionStyle = .none
            cell.accessibilityIdentifier = "cloudSync.status"
        case .openSettings:
            content.text = "打開「設定」App"
            content.secondaryText = "在 設定 → 你的名字 → iCloud 確認已登入並開啟 iCloud。"
            content.image = UIImage(systemName: "gearshape")
            cell.accessoryType = .disclosureIndicator
        case let .snapshot(snapshot):
            content.text = title(for: snapshot.kind)
            content.secondaryText = snapshot.modified.formatted(.dateTime.year().month().day().hour().minute())
            content.image = UIImage(systemName: "clock.arrow.circlepath")
            cell.accessoryType = .disclosureIndicator
        case .noSnapshots:
            content.text = "還沒有保護副本"
            content.textProperties.color = Theme.Color.textSecondary
            cell.selectionStyle = .none
        }
        cell.contentConfiguration = content
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch sections[indexPath.section].rows[indexPath.row] {
        case .openSettings:
            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        case let .snapshot(snapshot):
            backup?.preview(fileAt: snapshot.url, from: self, deleteAfterReading: false)
        default:
            break
        }
    }

    private var lastSuccessText: String? {
        // The end time of a CloudKit operation the system reported as successful — not a guarantee that every
        // device already has every change.
        monitor.lastSuccess.map { "最近一次完成的 iCloud 作業：\($0.formatted(.dateTime.month().day().hour().minute()))" }
    }

    private func title(for kind: ProtectionSnapshots.Snapshot.Kind) -> String {
        switch kind {
        case .preCloud: return "開啟 iCloud 同步前的資料"
        case let .account(hash): return hash == settings.accountFingerprint ? "目前 iCloud 帳號的資料" : "先前 iCloud 帳號的資料"
        case .local: return "未登入 iCloud 時的資料"
        case .beforeSharing: return "開始共享冰箱前的資料"
        }
    }

    private func symbol(for status: CloudSyncStatus) -> String {
        switch status {
        case .off: return "icloud.slash"
        case .unavailable: return "exclamationmark.icloud"
        case .available: return "checkmark.icloud"
        case .pending: return "icloud.and.arrow.up"
        case .syncing: return "arrow.triangle.2.circlepath.icloud"
        case .problem: return "exclamationmark.icloud"
        }
    }

    private func confirmToggle(_ on: Bool, toggle: UISwitch) {
        let message = on
            ? "這台裝置的資料會上傳到你的 iCloud，並和你其他開啟同步的裝置合併。開啟前會先在這台裝置保留一份保護副本。"
            : "關閉後這台裝置的變更不會再上傳，其他裝置的變更也不會下載。資料會保留在這台裝置上，不會被刪除。"
        let alert = UIAlertController(title: on ? "開啟 iCloud 同步？" : "關閉 iCloud 同步？", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in toggle.setOn(!on, animated: true) })
        alert.addAction(UIAlertAction(title: on ? "開啟" : "關閉", style: .default) { [weak self] _ in
            self?.settings.isEnabled = on
            NotificationCenter.default.post(name: .cloudSyncSettingDidChange, object: nil)
        })
        present(alert, animated: true)
    }
}
