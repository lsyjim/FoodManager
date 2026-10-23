import UIKit

/// Add / rename / delete flows shared by the home title menu and the management screen.
/// Every flow persists first; on failure the alert comes back with the user's input intact.
enum FridgeActions {
    /// Asks for a name and whether to start from the default layout or copy `sourceFridge`'s layout
    /// (structure only, never food). `onCreated` runs only after the fridge was saved.
    static func presentAdd(directory: FridgeDirectory, copyFrom sourceFridge: Fridge?, from presenter: UIViewController,
                           name: String = "", onCreated: @escaping (Fridge) -> Void) {
        guard directory.canAddFridge else {
            return FoodActions.showError(FridgePolicy.limitMessage, on: presenter)
        }
        var message = "最多可建立 \(FridgePolicy.maxRefrigerators) 台冰箱。"
        if let sourceFridge { message += "\n可複製「\(sourceFridge.name)」的隔層設定（不會複製食材）。" }
        let alert = UIAlertController(title: "新增冰箱", message: message, preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = "例如：儲藏室冰箱"
            field.text = name
            field.accessibilityIdentifier = "fridge.name"
        }
        func create(copying: Bool) {
            let typed = alert.textFields?.first?.text ?? ""
            do {
                let fridge = try directory.create(name: typed, copyingLayoutFrom: copying ? sourceFridge?.id : nil)
                onCreated(fridge)
            } catch {
                let text = (error as? FridgeDirectoryError)?.message ?? "無法建立冰箱，請再試一次。"
                retry(text, on: presenter) {
                    presentAdd(directory: directory, copyFrom: sourceFridge, from: presenter, name: typed, onCreated: onCreated)
                }
            }
        }
        alert.addAction(UIAlertAction(title: "使用預設隔層", style: .default) { _ in create(copying: false) })
        if sourceFridge != nil {
            alert.addAction(UIAlertAction(title: "複製目前隔層", style: .default) { _ in create(copying: true) })
        }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        presenter.present(alert, animated: true)
    }

    static func presentRename(_ fridge: Fridge, directory: FridgeDirectory, from presenter: UIViewController,
                              name: String? = nil, onDone: @escaping () -> Void) {
        let alert = UIAlertController(title: "重新命名冰箱", message: nil, preferredStyle: .alert)
        alert.addTextField { field in
            field.text = name ?? fridge.name
            field.clearButtonMode = .whileEditing
        }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "儲存", style: .default) { _ in
            let typed = alert.textFields?.first?.text ?? ""
            do {
                try directory.rename(fridge.id, to: typed)
                onDone()
            } catch {
                let text = (error as? FridgeDirectoryError)?.message ?? "無法重新命名，請再試一次。"
                retry(text, on: presenter) { presentRename(fridge, directory: directory, from: presenter, name: typed, onDone: onDone) }
            }
        })
        presenter.present(alert, animated: true)
    }

    /// Explains what deleting does, blocks if food is still inside, and only reports success after saving.
    static func presentDelete(_ fridge: Fridge, directory: FridgeDirectory, from presenter: UIViewController,
                              onDeleted: @escaping (_ remaining: Fridge) -> Void) {
        let summary: FridgeDeletionSummary
        do {
            summary = try directory.deletionSummary(for: fridge.id)
        } catch {
            return FoodActions.showError((error as? FridgeDirectoryError)?.message ?? "無法讀取冰箱資料，請再試一次。", on: presenter)
        }
        guard summary.activeFoodCount == 0 else {
            return FoodActions.showError(FridgeDirectoryError.hasActiveFood(summary.activeFoodCount).message
                                         + "\n（在食材列表左滑選「移動」，可移到「\(summary.remainingFridge.name)」。）", on: presenter)
        }
        var message = "「\(fridge.name)」的隔層設定會被刪除，無法復原。"
        if summary.historyCount > 0 {
            message += "\n\(summary.historyCount) 筆食用紀錄會移到「\(summary.remainingFridge.name)」保留。"
        }
        let alert = UIAlertController(title: "刪除冰箱？", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "刪除", style: .destructive) { _ in
            do {
                try directory.delete(fridge.id)
                onDeleted(summary.remainingFridge)
            } catch {
                FoodActions.showError((error as? FridgeDirectoryError)?.message ?? "刪除失敗，冰箱沒有變更。請再試一次。", on: presenter)
            }
        })
        presenter.present(alert, animated: true)
    }

    private static func retry(_ message: String, on presenter: UIViewController, again: @escaping () -> Void) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default) { _ in again() })
        presenter.present(alert, animated: true)
    }
}

/// Simple list of the user's fridges: switch, rename, delete, add (up to the limit).
final class FridgeManagementViewController: UITableViewController {
    private let directory: FridgeDirectory
    private let currentFridgeID: () -> UUID
    /// Switches the app to a fridge (rebuilds the home screen).
    private let onSelect: (UUID) -> Void
    /// nil while shared fridges are off (no sharing rows or labels at all).
    private let sharing: SharingService?
    private let makeBackupService: (() -> BackupService)?

    init(directory: FridgeDirectory, currentFridgeID: @escaping () -> UUID, onSelect: @escaping (UUID) -> Void,
         sharing: SharingService? = nil, makeBackupService: (() -> BackupService)? = nil) {
        self.directory = directory
        self.currentFridgeID = currentFridgeID
        self.onSelect = onSelect
        self.sharing = sharing
        self.makeBackupService = makeBackupService
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "管理冰箱"
        view.accessibilityIdentifier = "fridgeManagement"
        tableView.backgroundColor = Theme.Color.background
        NotificationCenter.default.addObserver(self, selector: #selector(reload), name: .fridgesDidChange, object: nil)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(false, animated: animated)
        reload()
    }

    // MARK: - Shared rows (section 1, after 新增冰箱)

    private enum SharedRow { case join, entry(InactiveSharedEntry) }
    private var sharedRows: [SharedRow] = []

    private func reloadSharedRows() {
        guard let sharing, sharing.policy.joinGate == .allowed else { return sharedRows = [] }
        sharedRows = sharing.inactiveEntries().map(SharedRow.entry) + [.join]
    }

    @objc private func reload() {
        reloadSharedRows()
        unplacedCount = (try? directory.unplacedItems().count) ?? 0
        tableView.reloadData()
    }

    // MARK: - Sync conflicts (section 2, only when needed)

    private enum Attention { case merge, unplaced }
    private var unplacedCount = 0
    private var attention: [Attention] {
        (directory.exceedsLimit ? [.merge] : []) + (unplacedCount > 0 ? [.unplaced] : [])
    }

    override func numberOfSections(in tableView: UITableView) -> Int { attention.isEmpty ? 2 : 3 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch section {
        case 0: return directory.fridges.count
        case 1: return 1 + sharedRows.count
        default: return attention.count
        }
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        section == 2 ? "需要處理" : nil
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch section {
        case 1: return FridgePolicy.limitMessage
        case 2: return "這通常發生在兩台裝置同步前各自建立了冰箱，或資料還在從 iCloud 下載。App 不會自動刪除或搬移任何東西，請選擇要怎麼處理。"
        default: return nil
        }
    }

    private func configureAttention(_ item: Attention, _ content: inout UIListContentConfiguration) {
        switch item {
        case .merge:
            content.text = "冰箱超過 \(FridgePolicy.maxRefrigerators) 台：合併冰箱"
            content.secondaryText = "把一台冰箱的食材、紀錄與磁鐵移到另一台，然後移除它。"
            content.image = UIImage(systemName: "arrow.triangle.merge")
        case .unplaced:
            content.text = "\(unplacedCount) 筆食材找不到所屬冰箱"
            content.secondaryText = "可能還在同步中，或那台冰箱已在其他裝置刪除。可以放到你選擇的隔層。"
            content.image = UIImage(systemName: "questionmark.folder")
        }
        content.imageProperties.tintColor = Theme.Color.destructive
    }

    private func handleAttention(_ item: Attention, at indexPath: IndexPath) {
        let source = tableView.cellForRow(at: indexPath)
        switch item {
        case .merge:
            choose(title: "要移除哪一台冰箱？", subtitle: "它的所有內容會移到另一台", options: directory.fridges, label: \.name, from: source) { [weak self] removed in
                guard let self else { return }
                let targets = self.directory.fridges.filter { $0.id != removed.id }
                self.choose(title: "移到哪一台冰箱？", subtitle: nil, options: targets, label: \.name, from: source) { target in
                    self.choose(title: "「\(removed.name)」的食材放到哪個隔層？", subtitle: nil, options: target.allCompartments,
                                label: { "\($0.parentZoneID.displayName) · \($0.name)" }, from: source) { compartment in
                        do {
                            try self.directory.merge(removed.id, into: target.id, compartmentID: compartment.id)
                            NotificationCenter.default.post(name: .foodInventoryDidChange, object: nil)
                            if removed.id == self.currentFridgeID() { self.onSelect(target.id) } else { self.reload() }
                        } catch {
                            FoodActions.showError("合併沒有完成，資料沒有變更。", on: self)
                        }
                    }
                }
            }
        case .unplaced:
            choose(title: "放到哪一台冰箱？", subtitle: nil, options: directory.fridges, label: \.name, from: source) { [weak self] target in
                guard let self else { return }
                self.choose(title: "放到哪個隔層？", subtitle: nil, options: target.allCompartments,
                            label: { "\($0.parentZoneID.displayName) · \($0.name)" }, from: source) { compartment in
                    do {
                        try self.directory.placeUnplacedItems(into: target.id, compartmentID: compartment.id)
                        self.reload()
                    } catch {
                        FoodActions.showError("沒有移動，資料沒有變更。", on: self)
                    }
                }
            }
        }
    }

    private func choose<T>(title: String, subtitle: String?, options: [T], label: @escaping (T) -> String, from source: UIView?,
                           then: @escaping (T) -> Void) {
        let sheet = UIAlertController(title: title, message: subtitle, preferredStyle: .actionSheet)
        for option in options {
            sheet.addAction(UIAlertAction(title: label(option), style: .default) { _ in then(option) })
        }
        sheet.addAction(UIAlertAction(title: "取消", style: .cancel))
        sheet.popoverPresentationController?.sourceView = source ?? view
        present(sheet, animated: true)
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.backgroundColor = Theme.Color.interior
        var content = cell.defaultContentConfiguration()
        content.textProperties.font = UIFont.preferredFont(forTextStyle: .body)
        content.secondaryTextProperties.font = UIFont.preferredFont(forTextStyle: .footnote)
        content.secondaryTextProperties.color = Theme.Color.textSecondary
        if indexPath.section == 2 {
            configureAttention(attention[indexPath.row], &content)
        } else if indexPath.section == 0 {
            let fridge = directory.fridges[indexPath.row]
            let foodCount = (try? directory.foodStore.activeItems(fridgeID: fridge.id).count).map { "\($0) 項食材" } ?? "—"
            content.text = fridge.name
            content.secondaryText = ([sharing?.ownership(of: fridge.id).selectorLabel].compactMap { $0 }
                                     + ["\(fridge.allCompartments.count) 個隔層", foodCount]).joined(separator: " · ")
            content.image = UIImage(named: "fridge_closed")
            content.imageProperties.maximumSize = CGSize(width: 28, height: 40)
            cell.accessoryType = fridge.id == currentFridgeID() ? .checkmark : .none
            cell.accessibilityValue = fridge.id == currentFridgeID() ? "目前使用中" : nil
        } else if indexPath.row > 0, let row = sharedRows[safeIndex: indexPath.row - 1] {
            switch row {
            case .join:
                content.text = "用邀請連結加入共享冰箱"
                content.image = UIImage(systemName: "link")
                content.imageProperties.tintColor = Theme.Color.stroke
                cell.accessibilityIdentifier = "fridgeManagement.join"
            case let .entry(entry):
                content.text = entry.name
                content.secondaryText = entry.ownership.selectorLabel
                content.image = UIImage(systemName: entry.ownership == .unavailableOrRevoked ? "exclamationmark.triangle" : "hourglass")
                content.imageProperties.tintColor = Theme.Color.textSecondary
                content.textProperties.color = Theme.Color.textSecondary
            }
        } else {
            content.text = "新增冰箱"
            content.image = UIImage(systemName: "plus")
            content.imageProperties.tintColor = Theme.Color.stroke
            let enabled = directory.canAddFridge
            content.textProperties.color = enabled ? Theme.Color.textPrimary : Theme.Color.textSecondary
            cell.accessibilityIdentifier = "fridgeManagement.add"
        }
        cell.contentConfiguration = content
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if indexPath.section == 2 { return handleAttention(attention[indexPath.row], at: indexPath) }
        if indexPath.section == 1, indexPath.row > 0, let row = sharedRows[safeIndex: indexPath.row - 1] {
            switch row {
            case .join: return presentJoin()
            case let .entry(entry): return handleInactive(entry, at: indexPath)
            }
        }
        guard indexPath.section == 0 else {
            let current = directory.fridge(id: currentFridgeID())
            return FridgeActions.presentAdd(directory: directory, copyFrom: current, from: self) { [weak self] fridge in
                self?.onSelect(fridge.id)
            }
        }
        let fridge = directory.fridges[indexPath.row]
        let sheet = UIAlertController(title: fridge.name, message: nil, preferredStyle: .actionSheet)
        if fridge.id != currentFridgeID() {
            sheet.addAction(UIAlertAction(title: "切換到這台冰箱", style: .default) { [weak self] _ in self?.onSelect(fridge.id) })
        }
        let ownership = sharing?.ownership(of: fridge.id) ?? .personalOwned
        let isOwner = ownership == .personalOwned || ownership == .sharedOwned
        if let sharing, ownership == .sharedOwned {
            sheet.addAction(UIAlertAction(title: "成員與申請", style: .default) { [weak self] _ in
                let members = SharedMembersViewController(sharing: sharing, fridgeID: fridge.id, fridgeName: fridge.name)
                members.onSharingStopped = { [weak self] in self?.reload() }
                self?.navigationController?.pushViewController(members, animated: true)
            })
            if let url = sharing.invitationURL(for: fridge.id) {
                sheet.addAction(UIAlertAction(title: "分享邀請連結", style: .default) { [weak self] _ in
                    self?.presentInvitation(url, fridgeName: fridge.name, at: indexPath)
                })
            }
        } else if let sharing, sharing.canOfferSharing(fridge.id) {
            sheet.addAction(UIAlertAction(title: "共享這台冰箱", style: .default) { [weak self] _ in
                self?.confirmSharing(fridge, at: indexPath)
            })
        }
        if isOwner {
            sheet.addAction(UIAlertAction(title: "重新命名", style: .default) { [weak self] _ in
                guard let self else { return }
                FridgeActions.presentRename(fridge, directory: self.directory, from: self) { [weak self] in self?.reload() }
            })
        }
        if let sharing, ownership == .sharedParticipant {
            sheet.addAction(UIAlertAction(title: "離開共享冰箱", style: .destructive) { [weak self] _ in
                self?.confirmLeave(fridge.id, name: fridge.name, sharing: sharing)
            })
        }
        if directory.fridges.count > 1 && ownership == .personalOwned {
            sheet.addAction(UIAlertAction(title: "刪除冰箱", style: .destructive) { [weak self] _ in
                guard let self else { return }
                FridgeActions.presentDelete(fridge, directory: self.directory, from: self) { [weak self] remaining in
                    guard let self else { return }
                    if fridge.id == self.currentFridgeID() { self.onSelect(remaining.id) } else { self.reload() }
                }
            })
        }
        sheet.addAction(UIAlertAction(title: "取消", style: .cancel))
        sheet.popoverPresentationController?.sourceView = tableView.cellForRow(at: indexPath)
        present(sheet, animated: true)
    }

    // MARK: - Sharing (Phase 5D)

    private func confirmSharing(_ fridge: Fridge, at indexPath: IndexPath) {
        guard let sharing else { return }
        switch sharing.startGate {
        case .allowed: break
        case .disabled: return
        case let gate: return FoodActions.showError(SharingServiceError.notAllowed(gate).message, on: self)
        }
        let alert = UIAlertController(
            title: "共享「\(fridge.name)」？",
            message: "會產生一個邀請連結，可以用 LINE 等方式傳給家人。對方開啟後要先送出申請，經你同意才看得到冰箱內容；只拿到連結的人看不到任何資料。\n成員可以新增和編輯食材，冰箱名稱、隔層與磁鐵只有你能修改。開始前會先在這台裝置保留一份保護副本。",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "開始共享", style: .default) { [weak self] _ in self?.startSharing(fridge, at: indexPath) })
        present(alert, animated: true)
    }

    private func startSharing(_ fridge: Fridge, at indexPath: IndexPath) {
        guard let sharing, let makeBackupService else { return }
        let progress = UIAlertController(title: "正在共享…", message: "正在上傳到 iCloud，請稍候。", preferredStyle: .alert)
        present(progress, animated: true)
        Task { @MainActor [weak self] in
            do {
                let url = try await sharing.share(fridgeID: fridge.id, backups: makeBackupService())
                progress.dismiss(animated: true) {
                    guard let self else { return }
                    self.reload()
                    self.presentInvitation(url, fridgeName: fridge.name, at: indexPath)
                }
            } catch {
                let message = (error as? SharingServiceError)?.message ?? (error as? BackupError)?.message
                    ?? (error as? SharedStoreError)?.message ?? "共享沒有完成，冰箱沒有變更。請再試一次。"
                progress.dismiss(animated: true) {
                    guard let self else { return }
                    FoodActions.showError(message, on: self)
                }
            }
        }
    }

    /// System share sheet (LINE, Messages, Mail…). The link alone grants nothing: recipients must request access.
    private func presentInvitation(_ url: URL, fridgeName: String, at indexPath: IndexPath) {
        let text = "邀請你一起管理「\(fridgeName)」冰箱。開啟連結後送出申請，我同意後就能加入："
        let activity = UIActivityViewController(activityItems: [text, url], applicationActivities: nil)
        activity.popoverPresentationController?.sourceView = tableView.cellForRow(at: indexPath) ?? view
        present(activity, animated: true)
    }

    // MARK: - Joining and leaving (Phase 5D-4)

    private func presentJoin() {
        guard let sharing else { return }
        let alert = UIAlertController(title: "加入共享冰箱",
                                      message: "貼上家人傳來的邀請連結。送出申請後，要等冰箱主人同意才看得到內容。",
                                      preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = "https://www.icloud.com/share/…"
            field.text = UIPasteboard.general.hasURLs ? UIPasteboard.general.url?.absoluteString : nil
            field.keyboardType = .URL
            field.autocapitalizationType = .none
            field.accessibilityIdentifier = "fridgeManagement.joinLink"
        }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "送出", style: .default) { [weak self] _ in
            let text = alert.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard let self else { return }
            guard let url = URL(string: text) else { return FoodActions.showError(JoinError.invalidLink.message, on: self) }
            self.run({ try await sharing.join(url: url) }) { [weak self] outcome in
                guard let self else { return }
                switch outcome {
                case let .joined(id), let .alreadyJoined(id):
                    self.onSelect(id)
                case .waitingForApproval:
                    FoodActions.showError("已送出加入申請，冰箱主人同意後就會出現在這裡。", on: self)
                case .ownFridge:
                    FoodActions.showError("這是你自己共享的冰箱。", on: self)
                }
            }
        })
        present(alert, animated: true)
    }

    private func handleInactive(_ entry: InactiveSharedEntry, at indexPath: IndexPath) {
        guard let sharing else { return }
        let sheet = UIAlertController(title: entry.name, message: entry.ownership.selectorLabel, preferredStyle: .actionSheet)
        if entry.isRequest {
            sheet.addAction(UIAlertAction(title: "取消申請", style: .destructive) { [weak self] _ in
                try? sharing.cancelInvitation(entry.id)
                self?.reload()
            })
        } else {
            sheet.addAction(UIAlertAction(title: entry.ownership == .unavailableOrRevoked ? "從列表移除" : "離開共享冰箱",
                                          style: .destructive) { [weak self] _ in
                self?.run({ try await sharing.leave(fridgeID: entry.id) }) { [weak self] _ in self?.reload() }
            })
        }
        sheet.addAction(UIAlertAction(title: "取消", style: .cancel))
        sheet.popoverPresentationController?.sourceView = tableView.cellForRow(at: indexPath)
        present(sheet, animated: true)
    }

    private func confirmLeave(_ fridgeID: UUID, name: String, sharing: SharingService) {
        let alert = UIAlertController(title: "離開「\(name)」？", message: "離開後這台冰箱會從你的裝置移除，冰箱主人和其他成員的資料不受影響。要再加入，需要重新申請。",
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "離開", style: .destructive) { [weak self] _ in
            self?.run({ try await sharing.leave(fridgeID: fridgeID) }) { [weak self] _ in
                guard let self else { return }
                if fridgeID == self.currentFridgeID(), let other = self.directory.fridges.first(where: { $0.id != fridgeID }) {
                    self.onSelect(other.id)
                } else {
                    self.onSelect(self.currentFridgeID())
                }
            }
        })
        present(alert, animated: true)
    }

    /// One server action with a progress alert; the result is shown only after the server answered.
    private func run<T>(_ action: @escaping () async throws -> T, then: @escaping (T) -> Void) {
        let progress = UIAlertController(title: "請稍候…", message: nil, preferredStyle: .alert)
        present(progress, animated: true)
        Task { @MainActor [weak self] in
            do {
                let value = try await action()
                progress.dismiss(animated: true) { then(value) }
            } catch {
                let message = (error as? JoinError)?.message ?? (error as? SharingServiceError)?.message
                    ?? (error as? SharedStoreError)?.message ?? "無法完成，請稍後再試。"
                progress.dismiss(animated: true) {
                    guard let self else { return }
                    FoodActions.showError(message, on: self)
                }
            }
        }
    }
}

private extension Array {
    subscript(safeIndex index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
