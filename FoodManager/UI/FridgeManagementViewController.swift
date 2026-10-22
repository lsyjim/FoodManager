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

    init(directory: FridgeDirectory, currentFridgeID: @escaping () -> UUID, onSelect: @escaping (UUID) -> Void) {
        self.directory = directory
        self.currentFridgeID = currentFridgeID
        self.onSelect = onSelect
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

    @objc private func reload() { tableView.reloadData() }

    override func numberOfSections(in tableView: UITableView) -> Int { 2 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == 0 ? directory.fridges.count : 1
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        section == 1 ? FridgePolicy.limitMessage : nil
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.backgroundColor = Theme.Color.interior
        var content = cell.defaultContentConfiguration()
        content.textProperties.font = UIFont.preferredFont(forTextStyle: .body)
        content.secondaryTextProperties.font = UIFont.preferredFont(forTextStyle: .footnote)
        content.secondaryTextProperties.color = Theme.Color.textSecondary
        if indexPath.section == 0 {
            let fridge = directory.fridges[indexPath.row]
            let foodCount = (try? directory.foodStore.activeItems(fridgeID: fridge.id).count).map { "\($0) 項食材" } ?? "—"
            content.text = fridge.name
            content.secondaryText = "\(fridge.allCompartments.count) 個隔層 · \(foodCount)"
            content.image = UIImage(named: "fridge_closed")
            content.imageProperties.maximumSize = CGSize(width: 28, height: 40)
            cell.accessoryType = fridge.id == currentFridgeID() ? .checkmark : .none
            cell.accessibilityValue = fridge.id == currentFridgeID() ? "目前使用中" : nil
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
        sheet.addAction(UIAlertAction(title: "重新命名", style: .default) { [weak self] _ in
            guard let self else { return }
            FridgeActions.presentRename(fridge, directory: self.directory, from: self) { [weak self] in self?.reload() }
        })
        if directory.fridges.count > 1 {
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
}
