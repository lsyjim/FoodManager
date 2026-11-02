import UIKit

/// Morandi tones for the three calendar event kinds (always paired with text for accessibility).
enum FoodEventStyle {
    static func color(_ kind: FoodEventKind) -> UIColor {
        switch kind {
        case .expiration: return UIColor(hex: 0xB8706A)       // muted red
        case .storageReminder: return UIColor(hex: 0xC9A15E)  // muted amber
        case .stored: return UIColor(hex: 0x8FA58A)           // muted sage
        }
    }
}

/// Shared filter bar of the calendar and statistics: which fridges, which temperature zone.
final class FoodScopeBar: UIStackView {
    let fridgeControl = UISegmentedControl(items: ["目前冰箱", "所有冰箱"])
    let storageControl = UISegmentedControl(items: StorageFilter.allCases.map(\.title))
    var onChange: (() -> Void)?

    init(showsFridgeChoice: Bool) {
        super.init(frame: .zero)
        axis = .vertical
        spacing = 8
        for control in [fridgeControl, storageControl] {
            control.selectedSegmentIndex = 0
            control.selectedSegmentTintColor = Theme.Color.interior
            control.addAction(UIAction { [weak self] _ in self?.onChange?() }, for: .valueChanged)
        }
        fridgeControl.accessibilityIdentifier = "scope.fridges"
        storageControl.accessibilityIdentifier = "scope.storage"
        if showsFridgeChoice { addArrangedSubview(fridgeControl) }
        addArrangedSubview(storageControl)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var allFridges: Bool { fridgeControl.selectedSegmentIndex == 1 }
    var storage: StorageFilter { StorageFilter.allCases[max(0, storageControl.selectedSegmentIndex)] }
}

/// 食材日曆: a month grid with dots for expiration dates, storage reminders and stored food, and the selected day's
/// events below. Built from the stored records (active and history) of the fridges in scope; a failed read is shown
/// as an error with a retry, never as an empty month.
final class FoodCalendarViewController: UIViewController, UICollectionViewDataSource, UICollectionViewDelegate,
                                        UITableViewDataSource, UITableViewDelegate {
    private let loader: FoodAnalyticsLoader
    private let currentFridgeID: UUID
    private let now: () -> Date
    private var model = FoodCalendarModel()
    private let calendar = Calendar.current

    private var data: FoodAnalyticsData?
    private var loadFailed = false
    private(set) var month: Date
    private(set) var selectedDay: Date
    private(set) var eventsByDay: [Date: [FoodCalendarEvent]] = [:]
    private var cells: [Date?] = []

    private lazy var scopeBar = FoodScopeBar(showsFridgeChoice: loader.directory.fridges.count > 1)
    private let monthLabel = UILabel()
    private lazy var previousButton = iconButton("chevron.left", label: "上個月") { [weak self] in self?.showMonth(offset: -1) }
    private lazy var nextButton = iconButton("chevron.right", label: "下個月") { [weak self] in self?.showMonth(offset: 1) }
    private lazy var todayButton = UIButton.sketchButton(title: "今天")
    private let weekdayRow = UIStackView()
    private lazy var grid = UICollectionView(frame: .zero, collectionViewLayout: Self.gridLayout())
    private var gridHeight: NSLayoutConstraint?
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let header = UIView()

    static let rowHeight: CGFloat = 46

    init(loader: FoodAnalyticsLoader, currentFridgeID: UUID, now: @escaping () -> Date = Date.init) {
        self.loader = loader
        self.currentFridgeID = currentFridgeID
        self.now = now
        let today = Calendar.current.startOfDay(for: now())
        month = FoodCalendarModel().startOfMonth(today)
        selectedDay = today
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "食材日曆"
        view.backgroundColor = Theme.Color.background
        view.accessibilityIdentifier = "calendar"
        buildHeader()
        tableView.backgroundColor = Theme.Color.background
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(FoodEventCell.self, forCellReuseIdentifier: FoodEventCell.reuseID)
        tableView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        scopeBar.onChange = { [weak self] in self?.recompute() }
        for name in [Notification.Name.foodInventoryDidChange, .fridgesDidChange] {
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
        guard width > 0 else { return }
        let size = header.systemLayoutSizeFitting(CGSize(width: width, height: 0), withHorizontalFittingPriority: .required,
                                                  verticalFittingPriority: .fittingSizeLevel)
        if header.frame.size != CGSize(width: width, height: size.height) {
            header.frame = CGRect(origin: .zero, size: CGSize(width: width, height: size.height))
            tableView.tableHeaderView = header
        }
    }

    // MARK: Header

    private func buildHeader() {
        monthLabel.font = UIFont.preferredFont(forTextStyle: .headline)
        monthLabel.adjustsFontForContentSizeCategory = true
        monthLabel.textColor = Theme.Color.textPrimary
        monthLabel.accessibilityTraits = .header
        todayButton.accessibilityIdentifier = "calendar.today"
        todayButton.addAction(UIAction { [weak self] _ in self?.jumpToToday() }, for: .touchUpInside)
        let navigation = UIStackView(arrangedSubviews: [previousButton, monthLabel, nextButton, UIView(), todayButton])
        navigation.alignment = .center
        navigation.spacing = 4

        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        weekdayRow.distribution = .fillEqually
        for index in 0..<7 {
            let label = UILabel()
            label.text = symbols[(index + calendar.firstWeekday - 1) % 7]
            label.font = UIFont.preferredFont(forTextStyle: .caption1)
            label.adjustsFontForContentSizeCategory = true
            label.textColor = Theme.Color.textSecondary
            label.textAlignment = .center
            label.isAccessibilityElement = false
            weekdayRow.addArrangedSubview(label)
        }

        grid.backgroundColor = .clear
        grid.isScrollEnabled = false
        grid.dataSource = self
        grid.delegate = self
        grid.register(CalendarDayCell.self, forCellWithReuseIdentifier: CalendarDayCell.reuseID)
        grid.accessibilityIdentifier = "calendar.grid"
        gridHeight = grid.heightAnchor.constraint(equalToConstant: Self.rowHeight * 6)
        gridHeight?.isActive = true

        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let legend = UIStackView(arrangedSubviews: FoodEventKind.allCases.map(Self.legendItem) + [spacer])
        legend.spacing = 14
        legend.isAccessibilityElement = true
        legend.accessibilityLabel = "紅點：到期日，黃點：保存提醒，綠點：放入冰箱"

        let stack = UIStackView(arrangedSubviews: [scopeBar, navigation, weekdayRow, grid, legend])
        stack.axis = .vertical
        stack.spacing = 10
        stack.setCustomSpacing(16, after: scopeBar)
        stack.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: header.topAnchor, constant: 12),
            stack.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: Theme.Metric.gutter),
            stack.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -Theme.Metric.gutter),
            stack.bottomAnchor.constraint(equalTo: header.bottomAnchor, constant: -4)
        ])
    }

    private static func legendItem(_ kind: FoodEventKind) -> UIView {
        let dot = UIView()
        dot.backgroundColor = FoodEventStyle.color(kind)
        dot.layer.cornerRadius = 4
        dot.widthAnchor.constraint(equalToConstant: 8).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 8).isActive = true
        let label = UILabel()
        label.text = kind.title
        label.font = UIFont.preferredFont(forTextStyle: .caption1)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = Theme.Color.textSecondary
        let item = UIStackView(arrangedSubviews: [dot, label])
        item.spacing = 5
        item.alignment = .center
        item.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentHuggingPriority(.required, for: .horizontal)
        return item
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

    private static func gridLayout() -> UICollectionViewCompositionalLayout {
        let item = NSCollectionLayoutItem(layoutSize: .init(widthDimension: .fractionalWidth(1 / 7), heightDimension: .fractionalHeight(1)))
        let group = NSCollectionLayoutGroup.horizontal(layoutSize: .init(widthDimension: .fractionalWidth(1),
                                                                         heightDimension: .absolute(rowHeight)), subitems: [item])
        return UICollectionViewCompositionalLayout(section: NSCollectionLayoutSection(group: group))
    }

    // MARK: Data

    @objc private func reload() {
        do {
            data = try loader.load()
            loadFailed = false
        } catch {
            data = nil
            loadFailed = true
        }
        recompute()
    }

    /// Scope or month changed: re-derive this month's events from the loaded records (no new read).
    private func recompute() {
        let scope = FoodAnalyticsScope(fridgeIDs: scopeBar.allFridges ? Set(loader.directory.fridges.map(\.id)) : [currentFridgeID],
                                       storage: scopeBar.storage)
        eventsByDay = data.map { model.eventsByDay(items: $0.filtered(scope), month: month) } ?? [:]
        cells = model.monthGrid(for: month)
        monthLabel.text = month.formatted(.dateTime.year().month(.wide))
        gridHeight?.constant = Self.rowHeight * CGFloat(max(cells.count / 7, 5))
        grid.reloadData()
        tableView.reloadData()
        view.setNeedsLayout()
    }

    func showMonth(offset: Int) {
        month = model.month(month, offsetBy: offset)
        if !calendar.isDate(selectedDay, equalTo: month, toGranularity: .month) { selectedDay = month }
        recompute()
    }

    func jumpToToday() {
        selectedDay = calendar.startOfDay(for: now())
        month = model.startOfMonth(selectedDay)
        recompute()
    }

    var selectedEvents: [FoodCalendarEvent] { eventsByDay[selectedDay] ?? [] }

    // MARK: Grid

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { cells.count }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: CalendarDayCell.reuseID, for: indexPath) as! CalendarDayCell
        guard let day = cells[indexPath.item] else {
            cell.configureEmpty()
            return cell
        }
        let events = eventsByDay[day]
        cell.configure(day: calendar.component(.day, from: day), kinds: FoodCalendarModel.kinds(events),
                       isToday: calendar.isDate(day, inSameDayAs: now()), isSelected: day == selectedDay,
                       accessibilityText: accessibilityText(day: day, events: events))
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let day = cells[indexPath.item] else { return }
        selectedDay = day
        grid.reloadData()
        tableView.reloadSections(IndexSet(integer: 0), with: .none)
    }

    private func accessibilityText(day: Date, events: [FoodCalendarEvent]?) -> String {
        let date = day.formatted(.dateTime.month().day().weekday(.wide))
        let counts = FoodEventKind.allCases.compactMap { kind -> String? in
            let count = events?.filter { $0.kind == kind }.count ?? 0
            return count > 0 ? "\(kind.title) \(count) 項" : nil
        }
        return counts.isEmpty ? date : "\(date)，" + counts.joined(separator: "，")
    }

    // MARK: Day events

    func numberOfSections(in tableView: UITableView) -> Int { 1 }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { max(selectedEvents.count, 1) }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        selectedDay.formatted(.dateTime.month().day().weekday(.wide))
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let event = selectedEvents[safeIndex: indexPath.row], let data else {
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            cell.backgroundColor = Theme.Color.interior
            var content = cell.defaultContentConfiguration()
            content.text = loadFailed ? "無法讀取食材資料，點這裡重試" : "這天沒有食材紀錄"
            content.textProperties.color = loadFailed ? Theme.Color.destructive : Theme.Color.textSecondary
            cell.contentConfiguration = content
            cell.selectionStyle = loadFailed ? .default : .none
            cell.accessibilityIdentifier = loadFailed ? "calendar.retry" : "calendar.empty"
            return cell
        }
        let cell = tableView.dequeueReusableCell(withIdentifier: FoodEventCell.reuseID, for: indexPath) as! FoodEventCell
        cell.configure(event: event, location: data.location(of: event.item, showFridge: scopeBar.allFridges), now: now())
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let event = selectedEvents[safeIndex: indexPath.row], let data else {
            if loadFailed { reload() }
            return
        }
        let detail = FoodEventDetailViewController(event: event, location: data.location(of: event.item, showFridge: true), now: now())
        navigationController?.pushViewController(detail, animated: true)
    }
}

final class CalendarDayCell: UICollectionViewCell {
    static let reuseID = "CalendarDayCell"
    private let number = UILabel()
    private let dots = UIStackView()
    private let selection = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        selection.layer.cornerRadius = 16
        selection.layer.borderColor = Theme.Color.stroke.cgColor
        number.font = UIFont.monospacedDigitSystemFont(ofSize: 15, weight: .regular)
        number.textAlignment = .center
        dots.spacing = 3
        dots.alignment = .center
        for view in [selection, number, dots] {
            view.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(view)
        }
        NSLayoutConstraint.activate([
            selection.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            selection.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 3),
            selection.widthAnchor.constraint(equalToConstant: 32),
            selection.heightAnchor.constraint(equalToConstant: 32),
            number.centerXAnchor.constraint(equalTo: selection.centerXAnchor),
            number.centerYAnchor.constraint(equalTo: selection.centerYAnchor),
            dots.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            dots.topAnchor.constraint(equalTo: selection.bottomAnchor, constant: 2),
            dots.heightAnchor.constraint(equalToConstant: 6)
        ])
        isAccessibilityElement = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configureEmpty() {
        number.text = nil
        dots.arrangedSubviews.forEach { $0.removeFromSuperview() }
        selection.backgroundColor = .clear
        selection.layer.borderWidth = 0
        isAccessibilityElement = false
    }

    func configure(day: Int, kinds: [FoodEventKind], isToday: Bool, isSelected: Bool, accessibilityText: String) {
        number.text = "\(day)"
        number.textColor = isSelected ? Theme.Color.interior : Theme.Color.textPrimary
        number.font = UIFont.monospacedDigitSystemFont(ofSize: 15, weight: isToday ? .bold : .regular)
        selection.backgroundColor = isSelected ? Theme.Color.stroke : .clear
        selection.layer.borderWidth = isToday && !isSelected ? 1 : 0
        dots.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for kind in kinds {
            let dot = UIView()
            dot.backgroundColor = FoodEventStyle.color(kind)
            dot.layer.cornerRadius = 3
            dot.widthAnchor.constraint(equalToConstant: 6).isActive = true
            dot.heightAnchor.constraint(equalToConstant: 6).isActive = true
            dots.addArrangedSubview(dot)
        }
        isAccessibilityElement = true
        accessibilityLabel = accessibilityText
        accessibilityTraits = isSelected ? [.button, .selected] : .button
        accessibilityIdentifier = "calendar.day.\(day)"
    }
}

final class FoodEventCell: UITableViewCell {
    static let reuseID = "FoodEventCell"

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: .subtitle, reuseIdentifier: reuseIdentifier)
        backgroundColor = Theme.Color.interior
        accessoryType = .disclosureIndicator
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(event: FoodCalendarEvent, location: String, now: Date) {
        var content = defaultContentConfiguration()
        content.image = CategoryIconProvider.image(for: event.item.categoryID, size: 36)
        content.text = event.item.name + (event.isHistorical ? "（已食用）" : "")
        content.textProperties.color = event.isHistorical ? Theme.Color.textSecondary : Theme.Color.textPrimary
        content.secondaryText = [FoodEventDetailViewController.statusText(event, now: now), location].filter { !$0.isEmpty }.joined(separator: "\n")
        content.secondaryTextProperties.color = Theme.Color.textSecondary
        content.secondaryTextProperties.numberOfLines = 0
        contentConfiguration = content
        let marker = UIView(frame: CGRect(x: 0, y: 0, width: 10, height: 10))
        marker.backgroundColor = FoodEventStyle.color(event.kind)
        marker.layer.cornerRadius = 5
        accessoryView = marker
        accessibilityIdentifier = "calendar.event"
    }
}

/// Read-only details of a calendar event; active food can be opened in its fridge.
final class FoodEventDetailViewController: UITableViewController {
    private let event: FoodCalendarEvent
    private let location: String
    private let now: Date
    private var rows: [(String, String)] = []

    init(event: FoodCalendarEvent, location: String, now: Date) {
        self.event = event
        self.location = location
        self.now = now
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    static func statusText(_ event: FoodCalendarEvent, now: Date) -> String {
        let item = event.item
        switch event.kind {
        case .expiration:
            return "到期日 · " + (FoodFormatting.expirationText(FoodReminderEvaluator().expirationStatus(of: item, now: now)) ?? "")
        case .storageReminder:
            return "保存提醒 · 設定存放 \(item.storageReminderDays ?? 0) 天"
        case .stored:
            if let consumed = item.consumedAt { return "放入冰箱 · \(consumed.formatted(.dateTime.month().day())) 已食用" }
            return "放入冰箱 · " + FoodFormatting.quantityText(item.quantity, unit: item.unit)
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = event.item.name
        tableView.backgroundColor = Theme.Color.background
        let item = event.item
        let date: (Date) -> String = { $0.formatted(.dateTime.year().month().day()) }
        rows = [("分類", FoodCategoryCatalog.category(id: item.categoryID).displayName),
                ("數量", FoodFormatting.quantityText(item.quantity, unit: item.unit)),
                ("位置", location.isEmpty ? "位置不存在" : location),
                ("放入日期", date(item.storedAt))]
        if let expiration = item.expirationDate { rows.append(("到期日", date(expiration))) }
        if let days = item.storageReminderDays { rows.append(("保存提醒", "存放 \(days) 天後提醒")) }
        if let consumed = item.consumedAt { rows.append(("食用日期", date(consumed))) }
    }

    override func numberOfSections(in tableView: UITableView) -> Int { event.isHistorical ? 1 : 2 }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { section == 0 ? rows.count : 1 }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        section == 0 && event.isHistorical ? "這是食用紀錄，已不在冰箱裡。" : nil
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
        cell.backgroundColor = Theme.Color.interior
        var content = cell.defaultContentConfiguration()
        if indexPath.section == 0 {
            content.text = rows[indexPath.row].0
            content.secondaryText = rows[indexPath.row].1
            content.prefersSideBySideTextAndSecondaryText = true
            cell.selectionStyle = .none
        } else {
            content.text = "在冰箱中查看"
            content.textProperties.color = Theme.Color.stroke
            content.textProperties.alignment = .center
            cell.accessibilityIdentifier = "calendar.openFood"
        }
        cell.contentConfiguration = content
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard indexPath.section == 1 else { return }
        // The usual deep link: switches fridge if needed and opens the food (or explains it no longer exists).
        AppNotificationRouter.shared.route(.link(AppDeepLink(.food(event.item.id), refrigeratorID: event.item.fridgeID)))
    }
}

private extension Array {
    subscript(safeIndex index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
