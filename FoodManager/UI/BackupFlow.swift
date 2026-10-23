import UIKit
import UniformTypeIdentifiers

/// 匯出備份 / 匯入備份 from Settings. Everything stays on the device (or wherever the user saves the file);
/// nothing is uploaded and file contents are never logged.
final class BackupFlow: NSObject, UIDocumentPickerDelegate {
    private let service: BackupService
    /// Called after a restore attempt that changed the database (success: nil; otherwise the message to show).
    private let onRestored: (String?) -> Void
    /// Whether restored data will also go to the user's iCloud (shown in the preview before confirming).
    private let syncsToCloud: () -> Bool
    private weak var presenter: UIViewController?

    init(service: BackupService, syncsToCloud: @escaping () -> Bool = { false }, onRestored: @escaping (String?) -> Void) {
        self.service = service
        self.syncsToCloud = syncsToCloud
        self.onRestored = onRestored
    }

    // MARK: - Export

    func export(from presenter: UIViewController, sourceView: UIView?, allowMissingPhotos: Bool = false) {
        let url: URL
        do {
            url = try service.exportFile(allowMissingPhotos: allowMissingPhotos)
        } catch BackupError.magnetImageMissing {
            // Never silently incomplete: ask first (a pending iCloud download must not block exporting).
            let alert = UIAlertController(title: "部分磁鐵照片不在這台裝置上", message: BackupError.magnetImageMissing.message
                                          + "那些磁鐵會保留位置，還原後顯示為空白卡片。", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "取消", style: .cancel))
            alert.addAction(UIAlertAction(title: "仍然匯出", style: .default) { [weak self, weak presenter] _ in
                guard let presenter else { return }
                self?.export(from: presenter, sourceView: sourceView, allowMissingPhotos: true)
            })
            presenter.present(alert, animated: true)
            return
        } catch {
            Self.showAlert(title: "無法匯出備份", message: (error as? BackupError)?.message ?? "請再試一次。", on: presenter)
            return
        }
        let share = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        share.popoverPresentationController?.sourceView = sourceView ?? presenter.view
        share.completionWithItemsHandler = { [service, weak presenter] _, completed, _, error in
            service.cleanUpExports() // the share sheet has made its own copy by now
            guard let presenter else { return }
            if completed {
                ToastView.show("備份已匯出", in: presenter.view)
            } else if error != nil {
                Self.showAlert(title: "匯出沒有完成", message: "備份檔沒有儲存，請再試一次。", on: presenter)
            }
        }
        presenter.present(share, animated: true)
    }

    // MARK: - Import

    func pickBackup(from presenter: UIViewController) {
        self.presenter = presenter
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.json], asCopy: true)
        picker.allowsMultipleSelection = false
        picker.delegate = self
        presenter.present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first, let presenter else { return }
        preview(fileAt: url, from: presenter, deleteAfterReading: true) // our private copy from the picker
    }

    /// Validates a backup file and shows its preview (nothing changes until the user confirms there).
    func preview(fileAt url: URL, from presenter: UIViewController, deleteAfterReading: Bool) {
        let service = self.service
        let result = Result { () throws -> FoodManagerBackup in
            let backup = try BackupService.readBackup(at: url)
            try service.checkRestorable(backup)
            return backup
        }
        if deleteAfterReading { try? FileManager.default.removeItem(at: url) }
        switch result {
        case let .success(backup):
            let preview = BackupPreviewViewController(backup: backup, service: service, syncsToCloud: syncsToCloud(),
                                                      onRestored: onRestored)
            presenter.navigationController?.pushViewController(preview, animated: true)
        case let .failure(error):
            Self.showAlert(title: "無法匯入備份", message: ((error as? BackupError)?.message ?? "無法讀取這個檔案。") + "\n目前的資料沒有變更。", on: presenter)
        }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        // Nothing was read or changed.
    }

    static func showAlert(title: String, message: String, on presenter: UIViewController) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default))
        presenter.present(alert, animated: true)
    }
}

/// Shows what a validated backup contains and asks for explicit confirmation before replacing everything.
final class BackupPreviewViewController: UITableViewController {
    private let backup: FoodManagerBackup
    private let summary: BackupSummary
    private let service: BackupService
    private let syncsToCloud: Bool
    private let onRestored: (String?) -> Void
    private var rows: [(title: String, value: String)] = []
    private var isRestoring = false

    init(backup: FoodManagerBackup, service: BackupService, syncsToCloud: Bool = false, onRestored: @escaping (String?) -> Void) {
        self.backup = backup
        summary = BackupValidator.summary(of: backup)
        self.service = service
        self.syncsToCloud = syncsToCloud
        self.onRestored = onRestored
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "匯入備份"
        view.accessibilityIdentifier = "backup.preview"
        tableView.backgroundColor = Theme.Color.background
        let date = summary.exportedAt.formatted(.dateTime.year().month().day().hour().minute())
        let compatibility = summary.unknownCategoryCount == 0
            ? "相容"
            : "相容（\(summary.unknownCategoryCount) 筆食材的分類此版本不認得，會顯示為「其他」）"
        rows = [("備份時間", date),
                ("冰箱", "\(summary.fridgeNames.count) 台：\(summary.fridgeNames.joined(separator: "、"))"),
                ("目前食材", "\(summary.activeFoodCount) 筆"),
                ("食用紀錄", "\(summary.historyCount) 筆"),
                ("常用食材", "\(summary.favoriteFoodCount) 個"),
                ("冰箱磁鐵", summary.missingPhotoCount == 0 ? "\(summary.magnetCount) 個"
                    : "\(summary.magnetCount) 個（\(summary.missingPhotoCount) 個缺少照片，會顯示為空白卡片）"),
                ("相容性", compatibility)]
    }

    override func numberOfSections(in tableView: UITableView) -> Int { 2 }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { section == 0 ? rows.count : 1 }
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? { section == 0 ? "備份內容" : nil }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        guard section == 1 else { return nil }
        let base = "還原會「取代」目前所有的冰箱、隔層、食材、食用紀錄、冰箱磁鐵與偏好設定，不會合併。還原前會先自動保留一份目前資料的保護副本；若還原失敗會恢復成原本的資料。"
        return syncsToCloud
            ? base + "\n\n目前已開啟 iCloud 同步：還原的內容也會同步到你目前的 iCloud，並取代你其他開啟同步的裝置上的資料（那些裝置上多出來的資料會被刪除）。這份檔案不需要登入寄件者的 iCloud 也能匯入。"
            : base + "\n\n目前沒有開啟 iCloud 同步：只會改變這台裝置上的資料。"
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
        cell.backgroundColor = Theme.Color.interior
        var content = cell.defaultContentConfiguration()
        if indexPath.section == 0 {
            content = UIListContentConfiguration.valueCell()
            content.text = rows[indexPath.row].title
            content.secondaryText = rows[indexPath.row].value
            content.secondaryTextProperties.numberOfLines = 0
            content.prefersSideBySideTextAndSecondaryText = rows[indexPath.row].value.count < 18
            cell.selectionStyle = .none
        } else {
            content.text = isRestoring ? "正在還原…" : "以此備份取代目前資料"
            content.textProperties.color = Theme.Color.destructive
            content.textProperties.alignment = .center
            cell.accessibilityIdentifier = "backup.restore"
        }
        content.textProperties.font = UIFont.preferredFont(forTextStyle: .body)
        cell.contentConfiguration = content
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard indexPath.section == 1, !isRestoring else { return }
        let alert = UIAlertController(title: "取代目前所有資料？",
                                      message: "目前的冰箱與食材會被這份備份完全取代（\(summary.fridgeNames.count) 台冰箱、\(summary.activeFoodCount) 筆食材、\(summary.historyCount) 筆紀錄）。這個動作無法復原。",
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "取代並還原", style: .destructive) { [weak self] _ in self?.restore() })
        present(alert, animated: true)
    }

    private func restore() {
        isRestoring = true
        tableView.reloadData()
        do {
            try service.restore(backup)
            onRestored(nil)
        } catch let error as BackupError {
            isRestoring = false
            tableView.reloadData()
            if case .restoreFailed = error {
                onRestored(error.message) // the database was touched: reload whatever is stored now
            } else {
                BackupFlow.showAlert(title: "沒有還原", message: error.message, on: self)
            }
        } catch {
            isRestoring = false
            tableView.reloadData()
            BackupFlow.showAlert(title: "沒有還原", message: "目前的資料沒有變更。", on: self)
        }
    }
}
