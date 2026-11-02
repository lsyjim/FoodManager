import UIKit

/// What 每週餐桌 and 購物清單 need from the session (supplied by the home screen).
struct MealPlannerContext {
    let store: MealPlanStore
    let directory: FridgeDirectory
    let foodStore: FoodStore
    let currentFridgeID: () -> UUID
    let ads: AdsCoordinator?
    /// Opens the food editor prefilled from a shopping item; calls back with the saved food record.
    let putIntoFridge: (ShoppingItem, UIViewController, @escaping (FoodItem) -> Void) -> Void

    /// Active food of the current fridge, or of every fridge the user can open. Throws on a read failure (shown as
    /// such, never as "nothing in the fridge").
    func activeFood(allFridges: Bool) throws -> [FoodItem] {
        let ids = allFridges ? directory.fridges.map(\.id) : [currentFridgeID()]
        return try ids.flatMap { try foodStore.activeItems(fridgeID: $0) }
    }

    /// Shopping items bought but not put into a fridge yet: counted as supply, so they're not offered again.
    func boughtItems() throws -> [ShoppingItem] {
        try store.shoppingItems().filter { $0.isPurchased && $0.storedFoodID == nil }
    }

    func fridgeName(_ id: UUID) -> String? { directory.fridge(id: id)?.name }

    func location(of food: FoodItem) -> String {
        let fridge = directory.fridge(id: food.fridgeID)
        let place = fridge?.allCompartments.first { $0.id == food.compartmentID }.map(CompartmentNaming.location)
        return [directory.fridges.count > 1 ? fridge?.name : nil, place].compactMap { $0 }.joined(separator: " · ")
    }
}

enum MealPlannerStyle {
    static func color(_ status: IngredientAvailabilityStatus) -> UIColor {
        switch status {
        case .ready: return UIColor(hex: 0x6F8F6A)
        case .insufficient: return UIColor(hex: 0xB0884A)
        case .needToBuy: return UIColor(hex: 0xA0574C)
        case .unknown, .notChecked: return Theme.Color.textSecondary
        }
    }
}

// MARK: - 每週餐桌

final class WeeklyMealPlannerViewController: UITableViewController {
    private let context: MealPlannerContext
    private let now: () -> Date
    private let week = MealWeek()
    private let analyzer = MealPlanAnalyzer()

    private(set) var weekStart: Date
    private(set) var selectedDay: Date
    private(set) var dishes: [PlannedDish] = []
    private(set) var availability: [UUID: IngredientAvailability] = [:]
    private var loadError: String?

    private let header = UIView()
    private let weekLabel = UILabel()
    private let scopeControl = UISegmentedControl(items: ["目前冰箱", "所有冰箱"])
    private let dayStrip = UIStackView()

    init(context: MealPlannerContext, now: @escaping () -> Date = Date.init) {
        self.context = context
        self.now = now
        let today = Calendar.current.startOfDay(for: now())
        weekStart = MealWeek().monday(of: today)
        selectedDay = today
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "每週餐桌"
        view.accessibilityIdentifier = "mealPlanner"
        tableView.backgroundColor = Theme.Color.background
        tableView.sectionHeaderHeight = UITableView.automaticDimension
        tableView.estimatedSectionHeaderHeight = 48
        tableView.register(MealSectionHeader.self, forHeaderFooterViewReuseIdentifier: MealSectionHeader.reuseID)
        navigationItem.rightBarButtonItem = UIBarButtonItem(image: UIImage(systemName: "basket"), primaryAction: UIAction { [weak self] _ in
            self?.openShoppingList()
        })
        navigationItem.rightBarButtonItem?.accessibilityLabel = "購物清單"
        buildHeader()
        for name in [Notification.Name.mealPlanDidChange, .foodInventoryDidChange, .fridgesDidChange, .shoppingListDidChange] {
            NotificationCenter.default.addObserver(self, selector: #selector(reload), name: name, object: nil)
        }
        reload()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(false, animated: animated)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let width = tableView.bounds.width
        let size = header.systemLayoutSizeFitting(CGSize(width: width, height: 0), withHorizontalFittingPriority: .required,
                                                  verticalFittingPriority: .fittingSizeLevel)
        if header.frame.size != CGSize(width: width, height: size.height) {
            header.frame = CGRect(x: 0, y: 0, width: width, height: size.height)
            tableView.tableHeaderView = header
        }
    }

    // MARK: Header

    private func buildHeader() {
        weekLabel.font = UIFont.preferredFont(forTextStyle: .headline)
        weekLabel.adjustsFontForContentSizeCategory = true
        weekLabel.textColor = Theme.Color.textPrimary
        let previous = iconButton("chevron.left", label: "上一週") { [weak self] in self?.showWeek(offset: -1) }
        let next = iconButton("chevron.right", label: "下一週") { [weak self] in self?.showWeek(offset: 1) }
        let thisWeek = UIButton.sketchButton(title: "本週")
        thisWeek.accessibilityIdentifier = "mealPlanner.thisWeek"
        thisWeek.addAction(UIAction { [weak self] _ in self?.showThisWeek() }, for: .touchUpInside)
        let navigation = UIStackView(arrangedSubviews: [previous, weekLabel, next, UIView(), thisWeek])
        navigation.alignment = .center
        navigation.spacing = 4

        scopeControl.selectedSegmentIndex = 0
        scopeControl.selectedSegmentTintColor = Theme.Color.interior
        scopeControl.accessibilityIdentifier = "mealPlanner.scope"
        scopeControl.addAction(UIAction { [weak self] _ in self?.reload() }, for: .valueChanged)

        dayStrip.distribution = .fillEqually
        dayStrip.spacing = 6

        let stack = UIStackView(arrangedSubviews: [navigation, dayStrip, scopeControl])
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: header.topAnchor, constant: 8),
            stack.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: Theme.Metric.gutter),
            stack.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -Theme.Metric.gutter),
            stack.bottomAnchor.constraint(equalTo: header.bottomAnchor, constant: -4)
        ])
    }

    private func iconButton(_ symbol: String, label: String, action: @escaping () -> Void) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: symbol), for: .normal)
        button.tintColor = Theme.Color.stroke
        button.accessibilityLabel = label
        button.widthAnchor.constraint(equalToConstant: Theme.Metric.minTouchTarget).isActive = true
        button.heightAnchor.constraint(equalToConstant: Theme.Metric.minTouchTarget).isActive = true
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return button
    }

    private func renderHeader() {
        let days = week.days(of: weekStart)
        if let first = days.first, let last = days.last {
            weekLabel.text = "\(first.formatted(.dateTime.month().day())) – \(last.formatted(.dateTime.month().day()))"
        }
        dayStrip.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let symbols = ["一", "二", "三", "四", "五", "六", "日"]
        let calendar = week.calendar
        for (index, day) in days.enumerated() {
            let key = DayKey(day)
            let count = dishes.filter { $0.day == key }.count
            let isSelected = calendar.isDate(day, inSameDayAs: selectedDay)
            let isToday = calendar.isDate(day, inSameDayAs: now())
            var config = UIButton.Configuration.plain()
            config.title = "\(symbols[index])\n\(calendar.component(.day, from: day))"
            config.subtitle = count > 0 ? "•" : " "
            config.titleAlignment = .center
            config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 0, bottom: 4, trailing: 0)
            config.baseForegroundColor = isSelected ? Theme.Color.interior : Theme.Color.textPrimary
            config.background.backgroundColor = isSelected ? Theme.Color.stroke : Theme.Color.interior
            config.background.cornerRadius = 12
            config.background.strokeColor = isToday && !isSelected ? Theme.Color.stroke : .clear
            config.background.strokeWidth = 1
            config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
                var attributes = attributes
                attributes.font = UIFont.monospacedDigitSystemFont(ofSize: 14, weight: isToday ? .semibold : .regular)
                return attributes
            }
            let button = UIButton(configuration: config)
            button.titleLabel?.numberOfLines = 2
            button.accessibilityLabel = day.formatted(.dateTime.month().day().weekday(.wide)) + (count > 0 ? "，\(count) 道菜" : "，未安排")
            button.accessibilityTraits = isSelected ? [.button, .selected] : .button
            button.accessibilityIdentifier = "mealPlanner.day.\(index)"
            button.addAction(UIAction { [weak self] _ in self?.select(day) }, for: .touchUpInside)
            dayStrip.addArrangedSubview(button)
        }
    }

    // MARK: Data

    private var allFridges: Bool { scopeControl.selectedSegmentIndex == 1 }

    @objc func reload() {
        let days = week.days(of: weekStart)
        guard let first = days.first, let last = days.last else { return }
        do {
            dishes = try context.store.dishes(from: DayKey(first), through: DayKey(last))
            // Demand is allocated over every uncompleted dish from today on (not just this week), so a later week
            // never looks better supplied than it is.
            let horizon = try context.store.dishes(from: DayKey(now()), through: DayKey("9999-12-31"))
            let all = Dictionary((horizon + dishes).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }).map(\.value)
            availability = analyzer.analyze(dishes: all, inventory: try context.activeFood(allFridges: allFridges),
                                            bought: try context.boughtItems(), now: now())
            loadError = nil
        } catch {
            loadError = "無法讀取每週餐桌或冰箱資料，請稍後再試。"
        }
        renderHeader()
        tableView.reloadData()
        view.setNeedsLayout()
    }

    func showWeek(offset: Int) {
        weekStart = week.week(weekStart, offsetBy: offset)
        selectedDay = week.calendar.date(byAdding: .day, value: dayIndex(of: selectedDay), to: weekStart) ?? weekStart
        reload()
    }

    func showThisWeek() {
        selectedDay = Calendar.current.startOfDay(for: now())
        weekStart = week.monday(of: selectedDay)
        reload()
    }

    func select(_ day: Date) {
        selectedDay = day
        renderHeader()
        tableView.reloadData()
    }

    private func dayIndex(of date: Date) -> Int {
        (week.calendar.dateComponents([.day], from: week.monday(of: date), to: week.calendar.startOfDay(for: date)).day ?? 0)
    }

    func dishes(for meal: MealType) -> [PlannedDish] {
        let key = DayKey(selectedDay)
        return dishes.filter { $0.day == key && $0.meal == meal }.sorted(by: SwiftDataMealPlanStore.dishOrder)
    }

    // MARK: Table

    override func numberOfSections(in tableView: UITableView) -> Int { MealType.allCases.count + 1 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        guard let meal = MealType.allCases[safe: section] else { return 1 }
        return max(dishes(for: meal).count, 1)
    }

    override func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        guard let meal = MealType.allCases[safe: section],
              let header = tableView.dequeueReusableHeaderFooterView(withIdentifier: MealSectionHeader.reuseID) as? MealSectionHeader else { return nil }
        let items = dishes(for: meal)
        header.configure(meal: meal, completed: !items.isEmpty && items.allSatisfy(\.isCompleted),
                         menu: items.isEmpty ? nil : mealMenu(meal, dishes: items)) { [weak self] in self?.addDish(meal) }
        return header
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        guard section == MealType.allCases.count else { return nil }
        return loadError ?? "食材狀態依日期先後分配：同一樣食材被好幾餐用到時，較早的餐先用冰箱裡的數量，所以不會重複計算。過期的食材不算可用；已完成或過去的餐點不檢查。標記完成不會自動扣冰箱裡的食材。"
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.backgroundColor = Theme.Color.interior
        var content = cell.defaultContentConfiguration()
        content.secondaryTextProperties.numberOfLines = 0
        guard let meal = MealType.allCases[safe: indexPath.section] else {
            content.text = "缺少的食材加入購物清單"
            content.image = UIImage(systemName: "cart.badge.plus")
            content.imageProperties.tintColor = Theme.Color.stroke
            cell.accessibilityIdentifier = "mealPlanner.addToShopping"
            cell.contentConfiguration = content
            return cell
        }
        guard let dish = dishes(for: meal)[safe: indexPath.row] else {
            content.text = "還沒安排\(meal.title)，點這裡新增"
            content.textProperties.color = Theme.Color.textSecondary
            cell.accessibilityIdentifier = "mealPlanner.empty.\(meal.rawValue)"
            cell.contentConfiguration = content
            return cell
        }
        content.text = dish.title
        content.textProperties.color = dish.isCompleted ? Theme.Color.textSecondary : Theme.Color.textPrimary
        content.secondaryAttributedText = ingredientSummary(dish)
        content.image = UIImage(systemName: dish.isCompleted ? "checkmark.circle.fill" : "circle")
        content.imageProperties.tintColor = dish.isCompleted ? MealPlannerStyle.color(.ready) : Theme.Color.divider
        cell.contentConfiguration = content
        cell.accessoryType = .disclosureIndicator
        cell.accessibilityIdentifier = "mealPlanner.dish"
        cell.accessibilityValue = dish.isCompleted ? "已完成" : nil
        return cell
    }

    private func ingredientSummary(_ dish: PlannedDish) -> NSAttributedString {
        guard !dish.ingredients.isEmpty else {
            return NSAttributedString(string: "未填食材", attributes: [.foregroundColor: Theme.Color.textSecondary])
        }
        let text = NSMutableAttributedString()
        for (index, ingredient) in dish.ingredients.sorted(by: { $0.sortOrder < $1.sortOrder }).enumerated() {
            if index > 0 { text.append(NSAttributedString(string: "  ·  ", attributes: [.foregroundColor: Theme.Color.divider])) }
            let info = availability[ingredient.id]
            let status = info?.status ?? .notChecked
            var label = ingredient.name
            if case .notChecked = status {} else {
                switch status {
                case let .insufficient(missing), let .needToBuy(missing?):
                    label += " 缺" + FoodFormatting.quantityText(missing, unit: ingredient.unit ?? "")
                default:
                    label += " " + status.title
                }
            }
            if info?.expiringSoon == true { label += "（快到期）" }
            text.append(NSAttributedString(string: label, attributes: [.foregroundColor: MealPlannerStyle.color(status)]))
        }
        return text
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let meal = MealType.allCases[safe: indexPath.section] else { return openShortagePreview() }
        if let dish = dishes(for: meal)[safe: indexPath.row] { edit(dish) } else { addDish(meal) }
    }

    override func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard let meal = MealType.allCases[safe: indexPath.section], let dish = dishes(for: meal)[safe: indexPath.row] else { return nil }
        let delete = UIContextualAction(style: .destructive, title: "刪除") { [weak self] _, _, done in
            self?.confirmDelete(dish)
            done(true)
        }
        let copy = UIContextualAction(style: .normal, title: "複製") { [weak self] _, _, done in
            self?.copy([dish])
            done(true)
        }
        copy.backgroundColor = Theme.Color.stroke
        return UISwipeActionsConfiguration(actions: [delete, copy])
    }

    override func tableView(_ tableView: UITableView, leadingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard let meal = MealType.allCases[safe: indexPath.section], let dish = dishes(for: meal)[safe: indexPath.row] else { return nil }
        let toggle = UIContextualAction(style: .normal, title: dish.isCompleted ? "取消完成" : "完成") { [weak self] _, _, done in
            self?.setCompleted([dish], !dish.isCompleted)
            done(true)
        }
        toggle.backgroundColor = MealPlannerStyle.color(.ready)
        return UISwipeActionsConfiguration(actions: [toggle])
    }

    // MARK: Actions

    private func mealMenu(_ meal: MealType, dishes: [PlannedDish]) -> UIMenu {
        let allDone = dishes.allSatisfy(\.isCompleted)
        return UIMenu(children: [
            UIAction(title: allDone ? "整餐取消完成" : "整餐標記完成", image: UIImage(systemName: "checkmark.circle")) { [weak self] _ in
                self?.setCompleted(dishes, !allDone)
            },
            UIAction(title: "複製整餐到…", image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in self?.copy(dishes) }
        ])
    }

    private func addDish(_ meal: MealType) {
        let dish = PlannedDish(day: DayKey(selectedDay), meal: meal, title: "",
                               sortOrder: (dishes(for: meal).map(\.sortOrder).max() ?? -1) + 1)
        presentEditor(dish, isNew: true)
    }

    private func edit(_ dish: PlannedDish) { presentEditor(dish, isNew: false) }

    private func presentEditor(_ dish: PlannedDish, isNew: Bool) {
        let editor = DishEditorViewController(dish: dish, isNew: isNew, context: context, analyze: { [weak self] edited in
            self?.availabilityForEditing(edited) ?? [:]
        })
        editor.onSaved = { [weak self] saved in
            guard let self else { return }
            self.selectedDay = saved.day.date() ?? self.selectedDay
            self.weekStart = self.week.monday(of: self.selectedDay)
            self.reload()
        }
        editor.onClosedAfterSave = { [weak self] in
            // Back on 每週餐桌 with nothing on top: the second dish saved since the app opened may show an ad.
            guard let self else { return }
            self.context.ads?.mealPlanSaved(presenter: self, presenterIdle: self.presentedViewController == nil)
        }
        let navigation = UINavigationController(rootViewController: editor)
        navigation.modalPresentationStyle = .pageSheet
        navigation.sheetPresentationController?.detents = [.large()]
        present(navigation, animated: true)
    }

    /// Statuses for a dish being edited, allocated together with the rest of the plan.
    private func availabilityForEditing(_ dish: PlannedDish) -> [UUID: IngredientAvailability] {
        guard let horizon = try? context.store.dishes(from: DayKey(now()), through: DayKey("9999-12-31")),
              let food = try? context.activeFood(allFridges: allFridges),
              let bought = try? context.boughtItems() else { return [:] }
        let others = horizon.filter { $0.id != dish.id }
        return analyzer.analyze(dishes: others + [dish], inventory: food, bought: bought, now: now())
    }

    func setCompleted(_ items: [PlannedDish], _ completed: Bool) {
        // Completing never touches the fridge: no food is consumed or deducted.
        let updated = items.map { dish -> PlannedDish in
            var dish = dish
            dish.isCompleted = completed
            dish.updatedAt = now()
            return dish
        }
        do {
            try context.store.save(updated)
        } catch {
            FoodActions.showError((error as? MealPlanStoreError)?.message ?? "沒有儲存，請再試一次。", on: self)
        }
    }

    private func confirmDelete(_ dish: PlannedDish) {
        let alert = UIAlertController(title: "刪除「\(dish.title)」？", message: "只會刪除這道菜的規劃，不影響冰箱裡的食材。", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "刪除", style: .destructive) { [weak self] _ in
            guard let self else { return }
            do { try self.context.store.deleteDish(id: dish.id) } catch {
                FoodActions.showError("無法刪除，請再試一次。", on: self)
            }
        })
        present(alert, animated: true)
    }

    private func copy(_ items: [PlannedDish]) {
        guard let first = items.first else { return }
        let picker = CopyDishViewController(day: first.day.date() ?? selectedDay, meal: first.meal, count: items.count) { [weak self] day, meal in
            guard let self else { return }
            let key = DayKey(day)
            let existing = (try? self.context.store.dishes(from: key, through: key))?.filter { $0.meal == meal } ?? []
            var order = (existing.map(\.sortOrder).max() ?? -1) + 1
            let copies = items.sorted(by: SwiftDataMealPlanStore.dishOrder).map { dish -> PlannedDish in
                defer { order += 1 }
                return dish.copied(to: key, meal: meal, sortOrder: order, now: self.now())
            }
            do {
                try self.context.store.save(copies)
                ToastView.show("已複製到 \(day.formatted(.dateTime.month().day())) \(meal.title)", in: self.view)
            } catch {
                FoodActions.showError("沒有複製，請再試一次。", on: self)
            }
        }
        present(UINavigationController(rootViewController: picker), animated: true)
    }

    private func openShortagePreview() {
        let preview = ShoppingPreviewViewController(context: context, allFridges: allFridges, now: now)
        navigationController?.pushViewController(preview, animated: true)
    }

    private func openShoppingList() {
        navigationController?.pushViewController(ShoppingListViewController(context: context, now: now), animated: true)
    }
}

/// 早餐 / 午餐 / 晚餐 header with ⋯ (whole-meal actions) and + (add a dish). Reused by the table, never duplicated.
final class MealSectionHeader: UITableViewHeaderFooterView {
    static let reuseID = "MealSectionHeader"
    private let label = UILabel()
    private let addButton = UIButton(configuration: .plain())
    private let menuButton = UIButton(configuration: .plain())
    private var onAdd: (() -> Void)?

    override init(reuseIdentifier: String?) {
        super.init(reuseIdentifier: reuseIdentifier)
        label.font = UIFont.preferredFont(forTextStyle: .headline)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = Theme.Color.textPrimary
        label.accessibilityTraits = .header
        addButton.configuration?.image = UIImage(systemName: "plus.circle")
        addButton.configuration?.baseForegroundColor = Theme.Color.stroke
        addButton.addAction(UIAction { [weak self] _ in self?.onAdd?() }, for: .touchUpInside)
        menuButton.configuration?.image = UIImage(systemName: "ellipsis.circle")
        menuButton.configuration?.baseForegroundColor = Theme.Color.stroke
        menuButton.showsMenuAsPrimaryAction = true
        for button in [addButton, menuButton] {
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: Theme.Metric.minTouchTarget).isActive = true
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: Theme.Metric.minTouchTarget).isActive = true
        }
        let row = UIStackView(arrangedSubviews: [label, UIView(), menuButton, addButton])
        row.alignment = .center
        row.spacing = 4
        row.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            row.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            row.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor, constant: 8)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(meal: MealType, completed: Bool, menu: UIMenu?, onAdd: @escaping () -> Void) {
        label.text = meal.title + (completed ? "  ✓ 已完成" : "")
        addButton.accessibilityLabel = "新增\(meal.title)"
        addButton.accessibilityIdentifier = "mealPlanner.add.\(meal.rawValue)"
        menuButton.accessibilityLabel = "\(meal.title)選項"
        menuButton.menu = menu
        menuButton.isHidden = menu == nil
        self.onAdd = onAdd
    }
}

// MARK: - Dish editor

final class DishEditorViewController: UITableViewController, UITextFieldDelegate {
    private enum Section: Int, CaseIterable { case basics, ingredients, status }

    private(set) var dish: PlannedDish
    private let original: PlannedDish
    private let isNew: Bool
    private let context: MealPlannerContext
    private let analyze: (PlannedDish) -> [UUID: IngredientAvailability]
    private var availability: [UUID: IngredientAvailability] = [:]
    var onSaved: ((PlannedDish) -> Void)?
    var onClosedAfterSave: (() -> Void)?

    private let titleField = UITextField()
    private let datePicker = UIDatePicker()
    private let mealControl = UISegmentedControl(items: MealType.allCases.map(\.title))
    private let errorLabel = UILabel()

    init(dish: PlannedDish, isNew: Bool, context: MealPlannerContext, analyze: @escaping (PlannedDish) -> [UUID: IngredientAvailability]) {
        self.dish = dish
        original = dish
        self.isNew = isNew
        self.context = context
        self.analyze = analyze
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = isNew ? "新增餐點" : "編輯餐點"
        view.accessibilityIdentifier = "dishEditor"
        tableView.backgroundColor = Theme.Color.background
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "取消", primaryAction: UIAction { [weak self] _ in self?.cancel() })
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "儲存", primaryAction: UIAction { [weak self] _ in self?.save() })
        navigationItem.rightBarButtonItem?.style = .done
        navigationItem.rightBarButtonItem?.accessibilityIdentifier = "dishEditor.save"

        titleField.placeholder = "菜名，例如：番茄炒蛋"
        titleField.text = dish.title
        titleField.font = UIFont.preferredFont(forTextStyle: .body)
        titleField.adjustsFontForContentSizeCategory = true
        titleField.clearButtonMode = .whileEditing
        titleField.returnKeyType = .done
        titleField.delegate = self
        titleField.accessibilityIdentifier = "dishEditor.title"
        titleField.addAction(UIAction { [weak self] _ in self?.dish.title = self?.titleField.text ?? "" }, for: .editingChanged)

        datePicker.datePickerMode = .date
        datePicker.preferredDatePickerStyle = .compact
        datePicker.date = dish.day.date() ?? Date()
        datePicker.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.dish.day = DayKey(self.datePicker.date)
            self.refreshAvailability()
        }, for: .valueChanged)
        mealControl.selectedSegmentIndex = MealType.allCases.firstIndex(of: dish.meal) ?? 0
        mealControl.selectedSegmentTintColor = Theme.Color.interior
        mealControl.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.dish.meal = MealType.allCases[self.mealControl.selectedSegmentIndex]
        }, for: .valueChanged)

        errorLabel.textColor = Theme.Color.destructive
        errorLabel.font = UIFont.preferredFont(forTextStyle: .footnote)
        errorLabel.numberOfLines = 0
        refreshAvailability()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if isNew && dish.title.isEmpty { titleField.becomeFirstResponder() }
    }

    private var hasChanges: Bool { dish != original }

    private func refreshAvailability() {
        availability = analyze(dish)
        navigationController?.isModalInPresentation = hasChanges
        tableView.reloadData()
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }

    // MARK: Table

    override func numberOfSections(in tableView: UITableView) -> Int { isNew ? 2 : 3 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch Section(rawValue: section)! {
        case .basics: return 3
        case .ingredients: return dish.ingredients.count + 1
        case .status: return 1
        }
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        Section(rawValue: section) == .ingredients ? "食材" : nil
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch Section(rawValue: section)! {
        case .ingredients: return "數量可以不填，只確認冰箱裡有沒有。新增食材不會改變冰箱內容。"
        case .status: return "標記完成不會自動扣除冰箱裡的食材。"
        case .basics: return nil
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.backgroundColor = Theme.Color.interior
        cell.selectionStyle = .none
        switch Section(rawValue: indexPath.section)! {
        case .basics where indexPath.row == 1:
            // The standard date row: label on the left, the compact picker as the accessory (it sizes itself there).
            var content = cell.defaultContentConfiguration()
            content.text = "日期"
            cell.contentConfiguration = content
            datePicker.sizeToFit()
            cell.accessoryView = datePicker
        case .basics:
            let views: [UIView] = [titleField, UIView(), labelled("餐別", mealControl)]
            let content = views[indexPath.row]
            content.translatesAutoresizingMaskIntoConstraints = false
            cell.contentView.addSubview(content)
            NSLayoutConstraint.activate([
                content.topAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.topAnchor),
                content.bottomAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.bottomAnchor),
                content.leadingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.leadingAnchor),
                content.trailingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.trailingAnchor),
                content.heightAnchor.constraint(greaterThanOrEqualToConstant: 32)
            ])
            if indexPath.row == 0 { cell.accessibilityElements = [titleField] }
        case .ingredients:
            var content = cell.defaultContentConfiguration()
            if let ingredient = dish.ingredients.sorted(by: { $0.sortOrder < $1.sortOrder })[safe: indexPath.row] {
                let info = availability[ingredient.id]
                let quantity = ingredient.quantity.map { FoodFormatting.quantityText($0, unit: ingredient.unit ?? "") } ?? "未填數量"
                content.text = "\(ingredient.name)  \(quantity)"
                let status = info?.status ?? .notChecked
                let statusText = status == .notChecked ? "已完成或過去的餐點不檢查" : [status.title, info?.detail].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
                content.secondaryText = statusText
                content.secondaryTextProperties.color = MealPlannerStyle.color(status)
                content.secondaryTextProperties.numberOfLines = 0
                cell.accessoryType = .disclosureIndicator
                cell.selectionStyle = .default
                cell.accessibilityIdentifier = "dishEditor.ingredient"
            } else {
                content.text = "＋ 新增食材"
                content.textProperties.color = Theme.Color.stroke
                cell.selectionStyle = .default
                cell.accessibilityIdentifier = "dishEditor.addIngredient"
            }
            cell.contentConfiguration = content
        case .status:
            var content = cell.defaultContentConfiguration()
            content.text = "已完成"
            cell.contentConfiguration = content
            let toggle = UISwitch()
            toggle.isOn = dish.isCompleted
            toggle.onTintColor = MealPlannerStyle.color(.ready)
            toggle.addAction(UIAction { [weak self, weak toggle] _ in
                self?.dish.isCompleted = toggle?.isOn ?? false
                self?.refreshAvailability()
            }, for: .valueChanged)
            cell.accessoryView = toggle
        }
        return cell
    }

    private func labelled(_ title: String, _ control: UIView) -> UIView {
        let label = UILabel()
        label.text = title
        label.font = UIFont.preferredFont(forTextStyle: .body)
        label.adjustsFontForContentSizeCategory = true
        label.setContentHuggingPriority(.required, for: .horizontal)
        // The control keeps its natural size; the spacer takes the rest (a compact date picker would collapse otherwise).
        control.setContentHuggingPriority(.required, for: .horizontal)
        control.setContentCompressionResistancePriority(.required, for: .horizontal)
        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row = UIStackView(arrangedSubviews: [label, spacer, control])
        row.alignment = .center
        row.spacing = 12
        return row
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard Section(rawValue: indexPath.section) == .ingredients else { return }
        let sorted = dish.ingredients.sorted { $0.sortOrder < $1.sortOrder }
        let ingredient = sorted[safe: indexPath.row]
            ?? PlannedIngredient(name: "", sortOrder: (dish.ingredients.map(\.sortOrder).max() ?? -1) + 1)
        let editor = IngredientEditorViewController(ingredient: ingredient, isNew: sorted[safe: indexPath.row] == nil, context: context)
        editor.onDone = { [weak self] updated in
            guard let self else { return }
            if let index = self.dish.ingredients.firstIndex(where: { $0.id == updated.id }) {
                self.dish.ingredients[index] = updated
            } else {
                self.dish.ingredients.append(updated)
            }
            self.refreshAvailability()
        }
        navigationController?.pushViewController(editor, animated: true)
    }

    override func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard Section(rawValue: indexPath.section) == .ingredients,
              let ingredient = dish.ingredients.sorted(by: { $0.sortOrder < $1.sortOrder })[safe: indexPath.row] else { return nil }
        return UISwipeActionsConfiguration(actions: [UIContextualAction(style: .destructive, title: "移除") { [weak self] _, _, done in
            self?.dish.ingredients.removeAll { $0.id == ingredient.id }
            self?.refreshAvailability()
            done(true)
        }])
    }

    // MARK: Save / cancel

    private func cancel() {
        view.endEditing(true)
        guard hasChanges else { return dismiss(animated: true) }
        let alert = UIAlertController(title: "放棄這次的變更？", message: nil, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "繼續編輯", style: .cancel))
        alert.addAction(UIAlertAction(title: "放棄", style: .destructive) { [weak self] _ in self?.dismiss(animated: true) })
        present(alert, animated: true)
    }

    /// Saves; on failure the editor stays open with everything the user typed.
    func save() {
        view.endEditing(true)
        dish.title = (titleField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        dish.updatedAt = Date()
        if isNew { dish.createdAt = dish.updatedAt }
        do {
            try context.store.save(dish)
        } catch {
            let message = (error as? MealPlanStoreError)?.message ?? "儲存失敗，內容都還在，請再試一次。"
            return FoodActions.showError(message, on: self)
        }
        onSaved?(dish)
        let closed = onClosedAfterSave
        dismiss(animated: true) { closed?() }
    }
}

// MARK: - Ingredient editor

final class IngredientEditorViewController: UITableViewController {
    private var ingredient: PlannedIngredient
    private let isNew: Bool
    private let context: MealPlannerContext
    private let now: () -> Date
    var onDone: ((PlannedIngredient) -> Void)?

    private let nameField = UITextField()
    private let quantityField = UITextField()
    private let unitField = UITextField()
    /// Active food of every fridge the user can open, and the fridges in the order they're listed.
    private var inventory: [FoodItem] = []
    private var fridges: [(id: UUID, name: String)] = []
    private var loadError: String?
    /// Food shown under each fridge (filtered by what is typed), one table section per fridge.
    private var shown: [[FoodItem]] = []

    /// Sections: 0 fields, 1 what the fridges hold for it, then one per fridge.
    private let firstFridgeSection = 2

    init(ingredient: PlannedIngredient, isNew: Bool, context: MealPlannerContext, now: @escaping () -> Date = Date.init) {
        self.ingredient = ingredient
        self.isNew = isNew
        self.context = context
        self.now = now
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = isNew ? "新增食材" : "編輯食材"
        view.accessibilityIdentifier = "ingredientEditor"
        tableView.backgroundColor = Theme.Color.background
        tableView.keyboardDismissMode = .onDrag
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "完成", primaryAction: UIAction { [weak self] _ in self?.done() })
        navigationItem.rightBarButtonItem?.style = .done
        navigationItem.rightBarButtonItem?.accessibilityIdentifier = "ingredientEditor.done"
        do {
            inventory = try context.activeFood(allFridges: true)
        } catch {
            loadError = "無法讀取冰箱裡的食材，仍可直接輸入名稱。"
        }
        fridges = context.directory.fridges.map { ($0.id, $0.name) }

        configure(nameField, placeholder: "搜尋或輸入食材名稱", text: ingredient.name, id: "ingredientEditor.name")
        configure(quantityField, placeholder: "數量（可不填）", text: ingredient.quantity.map { FoodFormatting.number($0) }, id: "ingredientEditor.quantity")
        quantityField.keyboardType = .decimalPad
        configure(unitField, placeholder: "單位，例如：顆", text: ingredient.unit, id: "ingredientEditor.unit")
        nameField.addAction(UIAction { [weak self] _ in self?.nameChanged() }, for: .editingChanged)
        for field in [quantityField, unitField] {
            field.addAction(UIAction { [weak self] _ in self?.reloadResults() }, for: .editingChanged)
        }
        filter()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if ingredient.name.isEmpty { nameField.becomeFirstResponder() }
    }

    private func configure(_ field: UITextField, placeholder: String, text: String?, id: String) {
        field.placeholder = placeholder
        field.text = text
        field.font = UIFont.preferredFont(forTextStyle: .body)
        field.adjustsFontForContentSizeCategory = true
        field.clearButtonMode = .whileEditing
        field.accessibilityIdentifier = id
    }

    private var typed: String { (nameField.text ?? "").trimmingCharacters(in: .whitespaces) }

    private func nameChanged() {
        // A typed name that no longer fits the chosen record means the user wants something else.
        if let linked = ingredient.linkedFoodID, let food = inventory.first(where: { $0.id == linked }),
           IngredientNaming.key(food.name) != IngredientNaming.key(typed) {
            ingredient.linkedFoodID = nil
        }
        filter()
        reloadResults()
    }

    /// Everything when nothing is typed; otherwise names containing the text or meaning the same (synonyms).
    private func filter() {
        let key = IngredientNaming.key(typed)
        let fits: (FoodItem) -> Bool = { [typed] food in
            typed.isEmpty || food.name.localizedCaseInsensitiveContains(typed) || IngredientNaming.key(food.name) == key
        }
        shown = fridges.map { fridge in
            inventory.filter { $0.fridgeID == fridge.id && fits($0) }.sorted {
                let exact = (IngredientNaming.key($0.name) == key, IngredientNaming.key($1.name) == key)
                if exact.0 != exact.1 { return exact.0 }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        }
    }

    /// Updates the results without touching the field cells (rebuilding them while typing ends editing).
    private func reloadResults() {
        guard tableView.window != nil else { return tableView.reloadData() }
        UIView.performWithoutAnimation {
            tableView.reloadSections(IndexSet(1..<tableView.numberOfSections), with: .none)
        }
    }

    private func isExpired(_ food: FoodItem) -> Bool {
        if case .expired = FoodReminderEvaluator().expirationStatus(of: food, now: now()) { return true }
        return false
    }

    /// What the fridges hold for the typed name: the chosen record, or the total of same-named usable food.
    var supplySummary: String? {
        guard !typed.isEmpty else { return nil }
        if let linked = ingredient.linkedFoodID, let food = inventory.first(where: { $0.id == linked }) {
            let place = context.fridgeName(food.fridgeID).map { "（\($0)）" } ?? ""
            return isExpired(food) ? "選的這筆已過期，不會算進可用數量"
                : "只用這一筆：\(food.name) \(FoodFormatting.quantityText(food.quantity, unit: food.unit))\(place)"
        }
        let same = inventory.filter { IngredientNaming.key($0.name) == IngredientNaming.key(typed) }
        let usable = same.filter { !isExpired($0) }
        guard !usable.isEmpty else {
            return same.isEmpty ? "冰箱裡沒有「\(typed)」，會列為需要購買" : "冰箱裡的「\(typed)」都已過期，會列為需要購買"
        }
        let entered = (unitField.text ?? "").trimmingCharacters(in: .whitespaces)
        let unit = entered.isEmpty ? usable[0].unit : entered
        let amounts = usable.map { IngredientNaming.convert($0.quantity, from: $0.unit, to: unit) }
        guard !amounts.contains(nil) else { return "冰箱裡有 \(usable.count) 筆，單位不同，無法加總" }
        let total = amounts.compactMap { $0 }.reduce(0, +)
        return "所有冰箱共有 \(FoodFormatting.quantityText(total, unit: unit)) 可用" + (usable.count > 1 ? "（\(usable.count) 筆）" : "")
    }

    // MARK: Table

    override func numberOfSections(in tableView: UITableView) -> Int { firstFridgeSection + fridges.count }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch section {
        case 0: return 3
        case 1: return supplySummary == nil ? 0 : 1
        default: return shown[safe: section - firstFridgeSection]?.count ?? 0
        }
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        guard section >= firstFridgeSection, let fridge = fridges[safe: section - firstFridgeSection],
              !(shown[safe: section - firstFridgeSection]?.isEmpty ?? true) else { return nil }
        return fridge.name
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch section {
        case 0:
            return loadError ?? "點下方冰箱裡的食材就會帶入名稱與單位；冰箱裡沒有的也可以直接輸入。規劃餐點不會改變冰箱裡的食材。"
        case numberOfSections(in: tableView) - 1:
            return shown.allSatisfy(\.isEmpty) && !typed.isEmpty && loadError == nil ? "冰箱裡沒有符合「\(typed)」的食材" : nil
        default:
            return nil
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.backgroundColor = Theme.Color.interior
        var content = cell.defaultContentConfiguration()
        content.secondaryTextProperties.color = Theme.Color.textSecondary
        switch indexPath.section {
        case 0:
            let field = [nameField, quantityField, unitField][indexPath.row]
            field.translatesAutoresizingMaskIntoConstraints = false
            cell.contentView.addSubview(field)
            NSLayoutConstraint.activate([
                field.topAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.topAnchor),
                field.bottomAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.bottomAnchor),
                field.leadingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.leadingAnchor),
                field.trailingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.trailingAnchor),
                field.heightAnchor.constraint(greaterThanOrEqualToConstant: 32)
            ])
            cell.selectionStyle = .none
            return cell
        case 1:
            content.text = supplySummary
            content.textProperties.color = Theme.Color.textSecondary
            content.textProperties.font = UIFont.preferredFont(forTextStyle: .subheadline)
            content.image = UIImage(systemName: "refrigerator")
            content.imageProperties.tintColor = Theme.Color.stroke
            cell.selectionStyle = .none
            cell.accessibilityIdentifier = "ingredientEditor.supply"
        default:
            guard let food = shown[safe: indexPath.section - firstFridgeSection]?[safe: indexPath.row] else { break }
            let expired = isExpired(food)
            let expiry = expired ? "已過期，不會算進可用數量"
                : FoodFormatting.expirationText(FoodReminderEvaluator().expirationStatus(of: food, now: now()))
            content.text = "\(food.name)  \(FoodFormatting.quantityText(food.quantity, unit: food.unit))"
            content.secondaryText = [placeText(food), expiry].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            content.image = CategoryIconProvider.image(for: food.categoryID, size: 28)
            if expired { content.textProperties.color = Theme.Color.textSecondary }
            cell.accessoryType = ingredient.linkedFoodID == food.id ? .checkmark : .none
            cell.tintColor = Theme.Color.stroke
            cell.accessibilityIdentifier = "ingredientEditor.food"
        }
        cell.contentConfiguration = content
        return cell
    }

    /// Compartment only: the fridge is the section header.
    private func placeText(_ food: FoodItem) -> String? {
        context.directory.fridge(id: food.fridgeID)?.allCompartments.first { $0.id == food.compartmentID }.map(CompartmentNaming.location)
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let food = shown[safe: indexPath.section - firstFridgeSection]?[safe: indexPath.row] else { return }
        if ingredient.linkedFoodID == food.id {
            ingredient.linkedFoodID = nil // tapping the chosen one again: back to matching by name
        } else {
            // One tap picks it: name, category, unit and this exact record.
            nameField.text = food.name
            ingredient.linkedFoodID = food.id
            ingredient.categoryID = food.categoryID
            if (unitField.text ?? "").isEmpty { unitField.text = food.unit }
            filter()
        }
        reloadResults()
    }

    private func done() {
        view.endEditing(true)
        let name = (nameField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= FoodValidationError.maxNameLength else {
            return FoodActions.showError("請輸入食材名稱（最多 \(FoodValidationError.maxNameLength) 字）", on: self)
        }
        let quantityText = (quantityField.text ?? "").trimmingCharacters(in: .whitespaces)
        var quantity: Decimal?
        if !quantityText.isEmpty {
            guard let parsed = FoodFormatting.parseQuantity(quantityText), parsed > 0 else {
                return FoodActions.showError("數量需大於 0，或留空", on: self)
            }
            quantity = parsed
        }
        let unit = (unitField.text ?? "").trimmingCharacters(in: .whitespaces)
        guard unit.count <= FoodValidationError.maxUnitLength else {
            return FoodActions.showError("單位最多 \(FoodValidationError.maxUnitLength) 字", on: self)
        }
        ingredient.name = name
        ingredient.quantity = quantity
        ingredient.unit = unit.isEmpty ? nil : unit
        if ingredient.categoryID == nil {
            ingredient.categoryID = inventory.first { IngredientNaming.key($0.name) == IngredientNaming.key(name) }?.categoryID
        }
        onDone?(ingredient)
        navigationController?.popViewController(animated: true)
    }
}

// MARK: - Copy

final class CopyDishViewController: UIViewController {
    private let picker = UIDatePicker()
    private let mealControl = UISegmentedControl(items: MealType.allCases.map(\.title))
    private let onCopy: (Date, MealType) -> Void
    private let count: Int

    init(day: Date, meal: MealType, count: Int, onCopy: @escaping (Date, MealType) -> Void) {
        self.onCopy = onCopy
        self.count = count
        super.init(nibName: nil, bundle: nil)
        picker.date = Calendar.current.date(byAdding: .day, value: 1, to: day) ?? day
        mealControl.selectedSegmentIndex = MealType.allCases.firstIndex(of: meal) ?? 0
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = count > 1 ? "複製整餐到…" : "複製到…"
        view.backgroundColor = Theme.Color.background
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "取消", primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "複製", primaryAction: UIAction { [weak self] _ in
            guard let self else { return }
            let day = self.picker.date, meal = MealType.allCases[self.mealControl.selectedSegmentIndex]
            self.dismiss(animated: true) { self.onCopy(day, meal) }
        })
        picker.datePickerMode = .date
        picker.preferredDatePickerStyle = .inline
        picker.tintColor = Theme.Color.stroke
        mealControl.selectedSegmentTintColor = Theme.Color.interior
        let note = UILabel()
        note.text = "複製後是獨立的一份，可以分別修改；食材與數量一起複製。"
        note.font = UIFont.preferredFont(forTextStyle: .footnote)
        note.textColor = Theme.Color.textSecondary
        note.numberOfLines = 0
        let stack = UIStackView(arrangedSubviews: [picker, mealControl, note])
        stack.axis = .vertical
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Theme.Metric.gutter),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Theme.Metric.gutter)
        ])
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
