import UIKit

/// 購物清單: its own records (never inventory). Three groups: 待購買, 已買到 (bought, not in a fridge yet) and 已放進冰箱.
/// A quick-add line at the top; shortages from 每週餐桌 are added through a preview. Marking an item bought can be
/// undone from the bar that appears, and a bought item can be moved back at any time.
final class ShoppingListViewController: UITableViewController, UITextFieldDelegate {
    private enum Section: Int, CaseIterable { case quickAdd, shortages, pending, bought, stored }

    private let context: MealPlannerContext
    private let now: () -> Date
    private(set) var items: [ShoppingItem] = []
    private(set) var shortages: [MealShortage] = []
    private var loadError: String?
    private let quickAddField = UITextField()
    private var undoBar: UndoBar?

    init(context: MealPlannerContext, now: @escaping () -> Date = Date.init) {
        self.context = context
        self.now = now
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "購物清單"
        view.accessibilityIdentifier = "shoppingList"
        tableView.backgroundColor = Theme.Color.background
        tableView.keyboardDismissMode = .onDrag
        tableView.register(ShoppingItemCell.self, forCellReuseIdentifier: ShoppingItemCell.reuseID)
        quickAddField.placeholder = "新增品項，例如：牛奶 2 瓶"
        quickAddField.font = UIFont.preferredFont(forTextStyle: .body)
        quickAddField.adjustsFontForContentSizeCategory = true
        quickAddField.returnKeyType = .done
        quickAddField.clearButtonMode = .whileEditing
        quickAddField.delegate = self
        quickAddField.accessibilityIdentifier = "shoppingList.quickAdd"
        for name in [Notification.Name.shoppingListDidChange, .mealPlanDidChange, .foodInventoryDidChange] {
            NotificationCenter.default.addObserver(self, selector: #selector(reload), name: name, object: nil)
        }
        reload()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(false, animated: animated)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        undoBar?.dismiss()
    }

    var pending: [ShoppingItem] { items.filter { !$0.isPurchased } }
    var bought: [ShoppingItem] {
        items.filter { $0.isPurchased && $0.storedFoodID == nil }.sorted { ($0.purchasedAt ?? .distantPast) > ($1.purchasedAt ?? .distantPast) }
    }
    var stored: [ShoppingItem] {
        items.filter { $0.storedFoodID != nil }.sorted { ($0.purchasedAt ?? .distantPast) > ($1.purchasedAt ?? .distantPast) }
    }
    /// Shortages not on the list yet. Bought items already count as supply, so they never come back here.
    var newShortages: [MealShortage] {
        shortages.filter { if case .alreadyListed = ShoppingMerge.action(for: $0, pending: pending) { return false } else { return true } }
    }

    @objc func reload() {
        do {
            items = try context.store.shoppingItems()
            loadError = nil
        } catch {
            loadError = "無法讀取購物清單，請稍後再試。"
        }
        if let dishes = try? context.store.dishes(from: DayKey(now()), through: DayKey("9999-12-31")),
           let food = try? context.activeFood(allFridges: true) {
            shortages = MealPlanAnalyzer().shortages(dishes: dishes, inventory: food, bought: bought, now: now())
        } else {
            shortages = []
        }
        // The quick-add cell is left alone so typing several items in a row keeps the keyboard up.
        guard tableView.window != nil else { return tableView.reloadData() }
        tableView.reloadSections(IndexSet(Section.shortages.rawValue..<Section.allCases.count), with: .fade)
    }

    // MARK: Table

    override func numberOfSections(in tableView: UITableView) -> Int { Section.allCases.count }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch Section(rawValue: section)! {
        case .quickAdd: return 1
        case .shortages: return newShortages.isEmpty ? 0 : 1
        case .pending: return max(pending.count, 1)
        case .bought: return bought.count
        case .stored: return stored.isEmpty ? 0 : stored.count + 1
        }
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch Section(rawValue: section)! {
        case .pending: return pending.isEmpty ? "待購買" : "待購買 \(pending.count)"
        case .bought: return bought.isEmpty ? nil : "已買到，還沒放進冰箱 \(bought.count)"
        case .stored: return stored.isEmpty ? nil : "已放進冰箱 \(stored.count)"
        default: return nil
        }
    }

    /// No gap for the shortage banner while there's nothing to show.
    override func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        Section(rawValue: section) == .shortages && newShortages.isEmpty ? .leastNormalMagnitude : UITableView.automaticDimension
    }

    override func tableView(_ tableView: UITableView, heightForFooterInSection section: Int) -> CGFloat {
        switch Section(rawValue: section)! {
        case .quickAdd: return 8
        case .shortages where newShortages.isEmpty: return .leastNormalMagnitude
        default: return UITableView.automaticDimension
        }
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch Section(rawValue: section)! {
        case .pending: return loadError ?? (pending.isEmpty ? nil : "點圓圈標記買到，點品項可以修改。")
        case .bought: return bought.isEmpty ? nil : "按錯了可以點綠色勾勾移回待購買。按「放入冰箱」會開啟新增食材，存好才算放進冰箱。"
        default: return nil
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch Section(rawValue: indexPath.section)! {
        case .quickAdd:
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            cell.backgroundColor = Theme.Color.interior
            cell.selectionStyle = .none
            let icon = UIImageView(image: UIImage(systemName: "plus"))
            icon.tintColor = Theme.Color.stroke
            icon.setContentHuggingPriority(.required, for: .horizontal)
            let row = UIStackView(arrangedSubviews: [icon, quickAddField])
            row.spacing = 10
            row.alignment = .center
            row.translatesAutoresizingMaskIntoConstraints = false
            cell.contentView.addSubview(row)
            NSLayoutConstraint.activate([
                row.topAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.topAnchor),
                row.bottomAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.bottomAnchor),
                row.leadingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.leadingAnchor),
                row.trailingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.trailingAnchor),
                quickAddField.heightAnchor.constraint(greaterThanOrEqualToConstant: 32)
            ])
            return cell
        case .shortages:
            let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
            cell.backgroundColor = Theme.Color.interior
            var content = cell.defaultContentConfiguration()
            let missing = newShortages
            content.text = "每週餐桌還缺 \(missing.count) 樣"
            content.secondaryText = missing.prefix(4).map(\.name).joined(separator: "、") + (missing.count > 4 ? "…" : "") + "　點這裡查看並加入"
            content.secondaryTextProperties.color = Theme.Color.textSecondary
            content.image = UIImage(systemName: "fork.knife")
            content.imageProperties.tintColor = Theme.Color.stroke
            cell.contentConfiguration = content
            cell.accessoryType = .disclosureIndicator
            cell.accessibilityIdentifier = "shoppingList.shortages"
            return cell
        case .pending:
            guard let item = pending[safe: indexPath.row] else {
                let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
                cell.backgroundColor = Theme.Color.interior
                var content = cell.defaultContentConfiguration()
                content.text = loadError == nil ? "還沒有要買的東西，在上方輸入就能新增" : "無法讀取，點這裡重試"
                content.textProperties.color = Theme.Color.textSecondary
                cell.contentConfiguration = content
                cell.selectionStyle = loadError == nil ? .none : .default
                cell.accessibilityIdentifier = "shoppingList.empty"
                return cell
            }
            let cell = itemCell(indexPath, item, state: .pending)
            cell.accessibilityIdentifier = "shoppingList.pending"
            return cell
        case .bought:
            let item = bought[indexPath.row]
            let cell = itemCell(indexPath, item, state: .bought)
            var config = UIButton.Configuration.bordered()
            config.title = "放入冰箱"
            config.baseForegroundColor = Theme.Color.textPrimary
            config.baseBackgroundColor = Theme.Color.background
            config.cornerStyle = .capsule
            config.buttonSize = .small
            let button = UIButton(configuration: config)
            button.accessibilityIdentifier = "shoppingList.putIntoFridge"
            button.addAction(UIAction { [weak self] _ in self?.putIntoFridge(item) }, for: .touchUpInside)
            button.sizeToFit()
            cell.accessoryView = button
            cell.accessibilityIdentifier = "shoppingList.bought"
            return cell
        case .stored:
            guard let item = stored[safe: indexPath.row] else {
                let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
                cell.backgroundColor = Theme.Color.interior
                var content = cell.defaultContentConfiguration()
                content.text = "清除已放進冰箱的品項"
                content.textProperties.color = Theme.Color.destructive
                cell.contentConfiguration = content
                cell.accessibilityIdentifier = "shoppingList.clearStored"
                return cell
            }
            let cell = itemCell(indexPath, item, state: .stored)
            cell.accessibilityIdentifier = "shoppingList.stored"
            return cell
        }
    }

    private func itemCell(_ indexPath: IndexPath, _ item: ShoppingItem, state: ShoppingItemCell.State) -> ShoppingItemCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: ShoppingItemCell.reuseID, for: indexPath) as! ShoppingItemCell
        let source = item.sourceKey != nil && !item.isUserEdited ? "來自每週餐桌" : nil
        cell.configure(item, state: state, detail: [item.quantityLabel, source].compactMap { $0 }.joined(separator: " · ")) { [weak self] in
            switch state {
            case .pending: self?.markBought(item)
            case .bought: self?.moveBack(item)
            case .stored: break
            }
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch Section(rawValue: indexPath.section)! {
        case .quickAdd: quickAddField.becomeFirstResponder()
        case .shortages:
            navigationController?.pushViewController(ShoppingPreviewViewController(context: context, allFridges: true, now: now), animated: true)
        case .pending:
            if let item = pending[safe: indexPath.row] { editItem(item) } else if loadError != nil { reload() }
        case .bought: editItem(bought[indexPath.row])
        case .stored: if stored[safe: indexPath.row] == nil { confirmClearStored() }
        }
    }

    override func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        let item: ShoppingItem?
        switch Section(rawValue: indexPath.section)! {
        case .pending: item = pending[safe: indexPath.row]
        case .bought: item = bought[safe: indexPath.row]
        case .stored: item = stored[safe: indexPath.row]
        default: item = nil
        }
        guard let item else { return nil }
        let delete = UIContextualAction(style: .destructive, title: "刪除") { [weak self] _, _, done in
            guard let self else { return done(false) }
            do { try self.context.store.deleteShoppingItem(id: item.id) } catch { FoodActions.showError("無法刪除，請再試一次。", on: self) }
            done(true)
        }
        guard item.isPurchased, item.storedFoodID == nil else { return UISwipeActionsConfiguration(actions: [delete]) }
        let back = UIContextualAction(style: .normal, title: "移回待購買") { [weak self] _, _, done in
            self?.moveBack(item)
            done(true)
        }
        back.backgroundColor = Theme.Color.stroke
        return UISwipeActionsConfiguration(actions: [delete, back])
    }

    // MARK: Actions

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        guard let entry = ShoppingQuickEntry.parse(textField.text ?? "") else {
            textField.resignFirstResponder()
            return true
        }
        var item = ShoppingItem(name: entry.name, unit: entry.unit, createdAt: now(), updatedAt: now())
        item.quantity = entry.quantity
        do {
            try context.store.save(item)
            textField.text = nil // stays focused for the next one
        } catch {
            FoodActions.showError((error as? MealPlanStoreError)?.message ?? "沒有儲存，請再試一次。", on: self)
        }
        return false
    }

    /// Marks it bought; the bar at the bottom can undo a mis-tap.
    func markBought(_ item: ShoppingItem) {
        guard setPurchased(item, true) else { return }
        undoBar?.dismiss()
        undoBar = UndoBar.show(in: navigationController?.view ?? view, text: "已標記買到「\(item.name)」") { [weak self] in
            guard let self, let current = self.items.first(where: { $0.id == item.id }), current.storedFoodID == nil else { return }
            self.setPurchased(current, false)
        }
    }

    func moveBack(_ item: ShoppingItem) {
        setPurchased(item, false)
    }

    @discardableResult
    func setPurchased(_ item: ShoppingItem, _ purchased: Bool) -> Bool {
        var updated = item
        updated.isPurchased = purchased
        updated.purchasedAt = purchased ? now() : nil
        updated.updatedAt = now()
        do {
            try context.store.save(updated)
            return true
        } catch {
            FoodActions.showError("沒有儲存，請再試一次。", on: self)
            return false
        }
    }

    private func confirmClearStored() {
        let items = stored
        let alert = UIAlertController(title: "清除 \(items.count) 個已放進冰箱的品項？", message: "只會從購物清單移除，冰箱裡的食材不受影響。", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "清除", style: .destructive) { [weak self] _ in
            guard let self else { return }
            do {
                for item in items { try self.context.store.deleteShoppingItem(id: item.id) }
            } catch {
                FoodActions.showError("沒有全部清除，請再試一次。", on: self)
            }
        })
        present(alert, animated: true)
    }

    /// Add (nil) or edit. Edits of an item that came from 每週餐桌 mark it as the user's, so later shortage updates
    /// never overwrite it.
    func editItem(_ item: ShoppingItem?) {
        let alert = UIAlertController(title: item == nil ? "新增品項" : "編輯品項", message: nil, preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = "名稱，例如：雞蛋"
            field.text = item?.name
            field.accessibilityIdentifier = "shoppingItem.name"
        }
        alert.addTextField { field in
            field.placeholder = "數量（可不填）"
            field.text = item?.quantity.map { FoodFormatting.number($0) }
            field.keyboardType = .decimalPad
            field.accessibilityIdentifier = "shoppingItem.quantity"
        }
        alert.addTextField { field in
            field.placeholder = "單位，例如：盒"
            field.text = item?.unit
            field.accessibilityIdentifier = "shoppingItem.unit"
        }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "儲存", style: .default) { [weak self, weak alert] _ in
            guard let self, let fields = alert?.textFields else { return }
            let name = (fields[0].text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let quantityText = (fields[1].text ?? "").trimmingCharacters(in: .whitespaces)
            let unit = (fields[2].text ?? "").trimmingCharacters(in: .whitespaces)
            var updated = item ?? ShoppingItem(name: name, createdAt: self.now(), updatedAt: self.now())
            updated.name = name
            updated.quantity = quantityText.isEmpty ? nil : FoodFormatting.parseQuantity(quantityText)
            if !quantityText.isEmpty && updated.quantity == nil { updated.quantityText = quantityText } // rejected by validation
            updated.unit = unit.isEmpty ? nil : unit
            updated.updatedAt = self.now()
            if item != nil && item != updated { updated.isUserEdited = true }
            do {
                try self.context.store.save(updated)
            } catch {
                let message = (error as? MealPlanStoreError)?.message ?? "沒有儲存，請再試一次。"
                let retry = UIAlertController(title: nil, message: message, preferredStyle: .alert)
                retry.addAction(UIAlertAction(title: "好", style: .default) { [weak self] _ in
                    var draft = updated
                    if draft.quantity == nil { draft.quantityText = nil }
                    self?.editItem(item == nil ? (name.isEmpty ? nil : draft) : draft)
                })
                self.present(retry, animated: true)
            }
        })
        present(alert, animated: true)
    }

    /// Opens the food editor prefilled from the item. Only after the food record saved is the item marked as put into
    /// the fridge; cancelling or a failed save leaves it unchanged.
    func putIntoFridge(_ item: ShoppingItem) {
        context.putIntoFridge(item, self) { [weak self] food in
            guard let self else { return }
            guard let current = try? self.context.store.shoppingItems().first(where: { $0.id == item.id }), current.storedFoodID == nil else { return }
            var stored = current
            stored.isPurchased = true
            stored.purchasedAt = stored.purchasedAt ?? self.now()
            stored.storedFoodID = food.id
            stored.updatedAt = self.now()
            try? self.context.store.save(stored)
        }
    }
}

// MARK: - Shortage preview

/// What the uncompleted plan still needs, compared with the shopping list. The user picks what to add; items already
/// listed (or edited by the user) are never duplicated or overwritten.
final class ShoppingPreviewViewController: UITableViewController {
    private let context: MealPlannerContext
    private let allFridges: Bool
    private let now: () -> Date
    private(set) var rows: [(shortage: MealShortage, action: ShoppingMerge.Action)] = []
    private(set) var selected = Set<String>()
    private var loadError: String?

    init(context: MealPlannerContext, allFridges: Bool, now: @escaping () -> Date = Date.init) {
        self.context = context
        self.allFridges = allFridges
        self.now = now
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "加入購物清單"
        view.accessibilityIdentifier = "shoppingPreview"
        tableView.backgroundColor = Theme.Color.background
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "加入", primaryAction: UIAction { [weak self] _ in self?.add() })
        navigationItem.rightBarButtonItem?.accessibilityIdentifier = "shoppingPreview.add"
        load()
    }

    func load() {
        do {
            let dishes = try context.store.dishes(from: DayKey(now()), through: DayKey("9999-12-31"))
            let list = try context.store.shoppingItems()
            let pending = list.filter { !$0.isPurchased }
            let shortages = MealPlanAnalyzer().shortages(dishes: dishes, inventory: try context.activeFood(allFridges: allFridges),
                                                         bought: list, now: now())
            rows = shortages.map { ($0, ShoppingMerge.action(for: $0, pending: pending)) }
            selected = Set(rows.filter { if case .alreadyListed = $0.action { return false } else { return true } }.map(\.shortage.key))
            loadError = nil
        } catch {
            rows = []
            loadError = "無法讀取資料，沒有任何變更。"
        }
        navigationItem.rightBarButtonItem?.isEnabled = !selected.isEmpty
        tableView.reloadData()
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { max(rows.count, 1) }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        loadError ?? "依今天起尚未完成的餐點計算，比對\(allFridges ? "所有冰箱" : "目前冰箱")裡未過期的食材，已買到還沒放進冰箱的也算。已在清單上的不會重複加入；你改過的品項不會被覆蓋。"
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.backgroundColor = Theme.Color.interior
        var content = cell.defaultContentConfiguration()
        content.secondaryTextProperties.color = Theme.Color.textSecondary
        content.secondaryTextProperties.numberOfLines = 0
        guard let row = rows[safe: indexPath.row] else {
            content.text = loadError == nil ? "目前規劃的餐點不缺食材" : "無法讀取"
            content.textProperties.color = Theme.Color.textSecondary
            cell.selectionStyle = .none
            cell.contentConfiguration = content
            return cell
        }
        let amount = row.shortage.quantity.map { " " + FoodFormatting.quantityText($0, unit: row.shortage.unit ?? "") } ?? ""
        content.text = row.shortage.name + amount
        var notes = ["用於：" + row.shortage.dishTitles.joined(separator: "、")]
        switch row.action {
        case .add: break
        case .update: notes.append("清單已有，會更新為這個數量")
        case let .alreadyListed(edited): notes.append(edited ? "清單已有（你修改過，不會變更）" : "清單已有")
        }
        content.secondaryText = notes.joined(separator: "\n")
        let isSelected = selected.contains(row.shortage.key)
        content.image = UIImage(systemName: isSelected ? "checkmark.circle.fill" : "circle")
        content.imageProperties.tintColor = isSelected ? Theme.Color.stroke : Theme.Color.divider
        if case .alreadyListed = row.action {
            cell.selectionStyle = .none
            content.image = UIImage(systemName: "checkmark.circle")
            content.imageProperties.tintColor = Theme.Color.divider
        }
        cell.accessibilityIdentifier = "shoppingPreview.row"
        cell.accessibilityTraits = isSelected ? [.button, .selected] : .button
        cell.contentConfiguration = content
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let row = rows[safe: indexPath.row] else { return }
        if case .alreadyListed = row.action { return }
        if selected.contains(row.shortage.key) { selected.remove(row.shortage.key) } else { selected.insert(row.shortage.key) }
        navigationItem.rightBarButtonItem?.isEnabled = !selected.isEmpty
        tableView.reloadRows(at: [indexPath], with: .none)
    }

    /// Saves the selected lines in one write.
    func add() {
        guard let pending = try? context.store.shoppingItems() else { return FoodActions.showError("無法讀取購物清單，沒有任何變更。", on: self) }
        var changes: [ShoppingItem] = []
        for row in rows where selected.contains(row.shortage.key) {
            switch row.action {
            case .add:
                var item = ShoppingItem(name: row.shortage.name, categoryID: row.shortage.categoryID, unit: row.shortage.unit,
                                        sourceKey: row.shortage.key, createdAt: now(), updatedAt: now())
                item.quantity = row.shortage.quantity
                changes.append(item)
            case let .update(id):
                guard var item = pending.first(where: { $0.id == id }) else { continue }
                item.quantity = row.shortage.quantity
                item.updatedAt = now()
                changes.append(item)
            case .alreadyListed:
                continue
            }
        }
        do {
            try context.store.save(changes)
        } catch {
            return FoodActions.showError("沒有加入，請再試一次。", on: self)
        }
        ToastView.show("已加入 \(changes.count) 項", in: navigationController?.view ?? view)
        navigationController?.popViewController(animated: true)
    }
}

// MARK: - Cells

/// One shopping item: a round check button (its own 44 pt target, so tapping the name edits instead), name and details.
final class ShoppingItemCell: UITableViewCell {
    static let reuseID = "ShoppingItemCell"
    enum State { case pending, bought, stored }

    private let checkButton = UIButton(type: .system)
    private let nameLabel = UILabel()
    private let detailLabel = UILabel()
    private var onCheck: (() -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = Theme.Color.interior
        checkButton.addAction(UIAction { [weak self] _ in self?.onCheck?() }, for: .touchUpInside)
        checkButton.setPreferredSymbolConfiguration(UIImage.SymbolConfiguration(textStyle: .title2), forImageIn: .normal)
        nameLabel.font = UIFont.preferredFont(forTextStyle: .body)
        nameLabel.adjustsFontForContentSizeCategory = true
        nameLabel.numberOfLines = 0
        detailLabel.font = UIFont.preferredFont(forTextStyle: .footnote)
        detailLabel.adjustsFontForContentSizeCategory = true
        detailLabel.textColor = Theme.Color.textSecondary
        detailLabel.numberOfLines = 0
        let texts = UIStackView(arrangedSubviews: [nameLabel, detailLabel])
        texts.axis = .vertical
        texts.spacing = 2
        let row = UIStackView(arrangedSubviews: [checkButton, texts])
        row.spacing = 8
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(row)
        NSLayoutConstraint.activate([
            checkButton.widthAnchor.constraint(equalToConstant: Theme.Metric.minTouchTarget),
            checkButton.heightAnchor.constraint(equalToConstant: Theme.Metric.minTouchTarget),
            row.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            row.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),
            row.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor, constant: -10),
            row.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func prepareForReuse() {
        super.prepareForReuse()
        accessoryView = nil
        onCheck = nil
    }

    func configure(_ item: ShoppingItem, state: State, detail: String, onCheck: @escaping () -> Void) {
        self.onCheck = onCheck
        nameLabel.text = item.name
        nameLabel.textColor = state == .pending ? Theme.Color.textPrimary : Theme.Color.textSecondary
        detailLabel.text = state == .stored ? [detail, "已放進冰箱"].filter { !$0.isEmpty }.joined(separator: " · ") : detail
        detailLabel.isHidden = detailLabel.text?.isEmpty ?? true
        switch state {
        case .pending:
            checkButton.setImage(UIImage(systemName: "circle"), for: .normal)
            checkButton.tintColor = Theme.Color.stroke
            checkButton.accessibilityLabel = "標記買到「\(item.name)」"
            checkButton.accessibilityIdentifier = "shoppingList.check"
        case .bought:
            checkButton.setImage(UIImage(systemName: "checkmark.circle.fill"), for: .normal)
            checkButton.tintColor = MealPlannerStyle.color(.ready)
            checkButton.accessibilityLabel = "移回待購買「\(item.name)」"
            checkButton.accessibilityIdentifier = "shoppingList.uncheck"
        case .stored:
            checkButton.setImage(UIImage(systemName: "refrigerator.fill"), for: .normal)
            checkButton.tintColor = Theme.Color.divider
            checkButton.accessibilityLabel = nil
            checkButton.accessibilityIdentifier = nil
        }
        checkButton.isUserInteractionEnabled = state != .stored
        checkButton.isAccessibilityElement = state != .stored
    }
}

/// A bar at the bottom for a few seconds: what just happened and 復原.
final class UndoBar: UIView {
    private var undo: (() -> Void)?
    private var timer: Timer?

    static func show(in host: UIView, text: String, seconds: TimeInterval = 4, undo: @escaping () -> Void) -> UndoBar {
        let bar = UndoBar()
        bar.undo = undo
        bar.backgroundColor = Theme.Color.textPrimary
        bar.layer.cornerRadius = 14
        bar.accessibilityIdentifier = "shoppingList.undoBar"
        let label = UILabel()
        label.text = text
        label.textColor = Theme.Color.background
        label.font = UIFont.preferredFont(forTextStyle: .subheadline)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 2
        var config = UIButton.Configuration.plain()
        config.title = "復原"
        config.baseForegroundColor = Theme.Color.background
        let button = UIButton(configuration: config, primaryAction: UIAction { [weak bar] _ in
            bar?.undo?()
            bar?.dismiss()
        })
        button.titleLabel?.font = UIFont.preferredFont(forTextStyle: .subheadline).withWeight(.semibold)
        button.accessibilityIdentifier = "shoppingList.undo"
        button.setContentHuggingPriority(.required, for: .horizontal)
        let row = UIStackView(arrangedSubviews: [label, button])
        row.alignment = .center
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(row)
        bar.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(bar)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: bar.topAnchor, constant: 6),
            row.bottomAnchor.constraint(equalTo: bar.bottomAnchor, constant: -6),
            row.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -6),
            bar.leadingAnchor.constraint(equalTo: host.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            bar.trailingAnchor.constraint(equalTo: host.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            bar.bottomAnchor.constraint(equalTo: host.keyboardLayoutGuide.topAnchor, constant: -12),
            bar.heightAnchor.constraint(greaterThanOrEqualToConstant: Theme.Metric.minTouchTarget)
        ])
        bar.alpha = 0
        UIView.animate(withDuration: 0.2) { bar.alpha = 1 }
        UIAccessibility.post(notification: .announcement, argument: text)
        bar.timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak bar] _ in bar?.dismiss() }
        return bar
    }

    func dismiss() {
        timer?.invalidate()
        timer = nil
        undo = nil
        UIView.animate(withDuration: 0.2, animations: { self.alpha = 0 }, completion: { _ in self.removeFromSuperview() })
    }
}
