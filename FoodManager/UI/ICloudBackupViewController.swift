import UIKit

/// 設定 → 資料管理 → iCloud 備份 (Phase 5E): manual backups to the user's iCloud, manual restore of a chosen version,
/// and the local protection copies. Nothing here runs automatically, and nothing is shown as backed up before the
/// uploaded copy was verified.
final class ICloudBackupViewController: UITableViewController {
    private enum Row {
        case status, backUp, restore, versions, snapshot(ProtectionSnapshots.Snapshot), noSnapshots
    }

    private let service: ICloudBackupService
    private let backup: BackupFlow
    private let snapshots: ProtectionSnapshots
    private var sections: [(title: String?, footer: String?, rows: [Row])] = []
    private var isWorking = false

    init(service: ICloudBackupService, backup: BackupFlow, snapshots: ProtectionSnapshots = .shared) {
        self.service = service
        self.backup = backup
        self.snapshots = snapshots
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "iCloud 備份"
        view.accessibilityIdentifier = "icloudBackup"
        tableView.backgroundColor = Theme.Color.background
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        rebuild()
    }

    private func rebuild() {
        let copies = snapshots.list()
        sections = [
            (nil, "資料只存在這台裝置，不會自動上傳或下載。需要時再手動備份到你自己的 iCloud；iCloud 會保留最近 \(ICloudBackupService.retainedVersions) 份備份，還原時可以選擇要哪一份。共享冰箱不包含在備份裡。",
             [.status, .backUp, .restore, .versions]),
            ("本機保護副本（只存在這台裝置）", "重要變更前 App 會自動在這台裝置留一份副本，需要時可從這裡還原（會取代目前的個人資料）。",
             copies.isEmpty ? [.noSnapshots] : copies.map(Row.snapshot))
        ]
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
        content.secondaryTextProperties.color = Theme.Color.textSecondary
        content.imageProperties.tintColor = Theme.Color.stroke
        switch sections[indexPath.section].rows[indexPath.row] {
        case .status:
            content.text = service.lastVerifiedBackup == nil ? "這台裝置還沒有備份到 iCloud" : "最近一次 iCloud 備份"
            content.secondaryText = service.lastVerifiedBackup?.formatted(.dateTime.year().month().day().hour().minute())
            content.image = UIImage(systemName: service.lastVerifiedBackup == nil ? "icloud" : "checkmark.icloud")
            cell.selectionStyle = .none
            cell.accessibilityIdentifier = "icloudBackup.status"
        case .backUp:
            content.text = isWorking ? "處理中…" : "備份目前資料至 iCloud"
            content.image = UIImage(systemName: "icloud.and.arrow.up")
            cell.accessibilityIdentifier = "icloudBackup.backUp"
        case .restore:
            content.text = "從 iCloud 還原資料"
            content.image = UIImage(systemName: "icloud.and.arrow.down")
            cell.accessoryType = .disclosureIndicator
            cell.accessibilityIdentifier = "icloudBackup.restore"
        case .versions:
            content.text = "查看備份版本"
            content.image = UIImage(systemName: "clock")
            cell.accessoryType = .disclosureIndicator
        case let .snapshot(snapshot):
            content.text = Self.title(for: snapshot.kind)
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
        guard !isWorking else { return }
        switch sections[indexPath.section].rows[indexPath.row] {
        case .backUp:
            startBackup(allowMissingPhotos: false)
        case .restore:
            navigationController?.pushViewController(ICloudBackupVersionsViewController(service: service, backup: backup, restoring: true), animated: true)
        case .versions:
            navigationController?.pushViewController(ICloudBackupVersionsViewController(service: service, backup: backup, restoring: false), animated: true)
        case let .snapshot(snapshot):
            backup.preview(fileAt: snapshot.url, from: self, deleteAfterReading: false)
        default:
            break
        }
    }

    // MARK: Backup

    private func startBackup(allowMissingPhotos: Bool) {
        let local: FoodManagerBackup
        do {
            local = try backup.backupService.makeBackup(allowMissingPhotos: allowMissingPhotos)
        } catch BackupError.magnetImageMissing {
            let alert = UIAlertController(title: "部分磁鐵照片不在這台裝置上", message: BackupError.magnetImageMissing.message
                                          + "那些磁鐵會保留位置，還原後顯示為空白卡片。", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "取消", style: .cancel))
            alert.addAction(UIAlertAction(title: "仍然備份", style: .default) { [weak self] _ in self?.startBackup(allowMissingPhotos: true) })
            return present(alert, animated: true)
        } catch {
            return BackupFlow.showAlert(title: "無法備份", message: (error as? BackupError)?.message ?? "無法讀取目前的資料，請再試一次。", on: self)
        }
        setWorking(true)
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let existing = try await self.service.versions()
                self.setWorking(false)
                self.confirmBackup(local, existing: existing)
            } catch {
                self.setWorking(false)
                BackupFlow.showAlert(title: "無法備份", message: ICloudBackupError.from(error).message, on: self)
            }
        }
    }

    private func confirmBackup(_ local: FoodManagerBackup, existing: [ICloudBackupVersion]) {
        let summary = BackupValidator.summary(of: local)
        var message = "將備份 \(summary.fridgeNames.count) 台冰箱、\(summary.activeFoodCount) 筆食材、\(summary.historyCount) 筆食用紀錄、\(summary.magnetCount) 個磁鐵。"
        if let latest = existing.first {
            message += "\n\niCloud 上已有 \(existing.count) 份備份（最新：\(latest.createdAt.formatted(.dateTime.year().month().day().hour().minute()))）。這次會新增一份，舊的不會被覆蓋；只保留最近 \(ICloudBackupService.retainedVersions) 份。"
        }
        let alert = UIAlertController(title: "備份到 iCloud？", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "備份", style: .default) { [weak self] _ in self?.upload(local) })
        present(alert, animated: true)
    }

    private func upload(_ local: FoodManagerBackup) {
        setWorking(true)
        let progress = UIAlertController(title: "正在備份到 iCloud…", message: "上傳後會再下載一次確認內容完整。", preferredStyle: .alert)
        present(progress, animated: true)
        Task { @MainActor [weak self] in
            do {
                _ = try await self?.service.upload(local)
                progress.dismiss(animated: true) {
                    guard let self else { return }
                    self.setWorking(false)
                    ToastView.show("已備份到 iCloud", in: self.view)
                }
            } catch {
                progress.dismiss(animated: true) {
                    guard let self else { return }
                    self.setWorking(false)
                    BackupFlow.showAlert(title: "備份沒有完成", message: ICloudBackupError.from(error).message, on: self)
                }
            }
        }
    }

    private func setWorking(_ working: Bool) {
        isWorking = working
        rebuild()
    }

    static func title(for kind: ProtectionSnapshots.Snapshot.Kind) -> String {
        switch kind {
        case .preCloud: return "開啟 iCloud 同步前的資料"
        case .account: return "先前 iCloud 同步時的資料"
        case .local: return "未登入 iCloud 時的資料"
        case .beforeSharing: return "開始共享冰箱前的資料"
        case .beforeLocalOnly: return "改為手動 iCloud 備份前的資料"
        }
    }
}

/// The iCloud backup versions (metadata only). With `restoring`, picking one downloads it, verifies it and opens the
/// usual restore preview, where the user confirms (or exports the current data first). Nothing changes before that.
final class ICloudBackupVersionsViewController: UITableViewController {
    private let service: ICloudBackupService
    private let backup: BackupFlow
    private let restoring: Bool
    private var versions: [ICloudBackupVersion]?
    private var loadError: String?

    init(service: ICloudBackupService, backup: BackupFlow, restoring: Bool) {
        self.service = service
        self.backup = backup
        self.restoring = restoring
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = restoring ? "從 iCloud 還原" : "iCloud 備份版本"
        view.accessibilityIdentifier = "icloudBackup.versions"
        tableView.backgroundColor = Theme.Color.background
        refreshControl = UIRefreshControl()
        refreshControl?.addTarget(self, action: #selector(load), for: .valueChanged)
        load()
    }

    @objc private func load() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                self.versions = try await self.service.versions()
                self.loadError = nil
            } catch {
                self.loadError = ICloudBackupError.from(error).message
            }
            self.refreshControl?.endRefreshing()
            self.tableView.reloadData()
        }
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { max(versions?.count ?? 0, 1) }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        if let loadError { return loadError }
        return restoring ? "選擇一份備份。還原會取代這台裝置上目前的個人冰箱與食材（共享冰箱不受影響），確認前不會有任何變更。" : nil
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.backgroundColor = Theme.Color.interior
        var content = cell.defaultContentConfiguration()
        content.secondaryTextProperties.color = Theme.Color.textSecondary
        if let version = versions?[safeIndex: indexPath.row] {
            content.text = version.createdAt.formatted(.dateTime.year().month().day().hour().minute())
            content.secondaryText = "\(version.fridgeCount) 台冰箱 · \(version.activeFoodCount) 筆食材 · \(version.historyCount) 筆紀錄 · \(version.magnetCount) 個磁鐵"
            content.image = UIImage(systemName: "doc.on.clipboard")
            content.imageProperties.tintColor = Theme.Color.stroke
            cell.accessoryType = restoring ? .disclosureIndicator : .none
            cell.selectionStyle = restoring ? .default : .none
            cell.accessibilityIdentifier = "icloudBackup.version"
        } else {
            content.text = versions == nil ? (loadError == nil ? "讀取中…" : "無法讀取") : "iCloud 上沒有備份"
            content.textProperties.color = Theme.Color.textSecondary
            cell.selectionStyle = .none
        }
        cell.contentConfiguration = content
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard restoring, let version = versions?[safeIndex: indexPath.row] else { return }
        let progress = UIAlertController(title: "正在下載備份…", message: "下載後會先檢查內容，確認前不會變更任何資料。", preferredStyle: .alert)
        present(progress, animated: true)
        Task { @MainActor [weak self] in
            do {
                guard let downloaded = try await self?.service.download(version) else { return }
                progress.dismiss(animated: true) {
                    guard let self else { return }
                    self.backup.preview(backup: downloaded, from: self)
                }
            } catch {
                progress.dismiss(animated: true) {
                    guard let self else { return }
                    BackupFlow.showAlert(title: "無法使用這份備份", message: ICloudBackupError.from(error).message, on: self)
                }
            }
        }
    }
}

private extension Array {
    subscript(safeIndex index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
