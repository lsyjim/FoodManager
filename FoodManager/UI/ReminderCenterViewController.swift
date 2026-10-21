import UIKit

/// In-app reminder center: 即將到期 / 已過期 / 保存提醒 for 全部 / 冷藏 / 冷凍, computed live from persisted
/// inventory (works without notification permission). Tapping a food opens its editor.
final class ReminderCenterViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    var onOpenFood: ((UUID) -> Void)?
    var onOpenSettings: (() -> Void)?

    private(set) var storageFilter: StorageFilter
    private(set) var kindFilter: ReminderKindFilter
    private let inventory: FoodInventoryService
    private let compartments: () -> [Compartment]
    private let builder = ReminderCenterBuilder()
    private(set) var entries: [ReminderEntry] = []

    private let filterControl = UISegmentedControl(items: StorageFilter.allCases.map(\.title))
    private let tiles: [(ReminderKindFilter, ReminderTile)] = [
        (.expiringSoon, ReminderTile(title: ReminderKindFilter.expiringSoon.title)),
        (.expired, ReminderTile(title: ReminderKindFilter.expired.title)),
        (.storedTooLong, ReminderTile(title: ReminderKindFilter.storedTooLong.title)),
    ]
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let emptyView = UIStackView()
    private let emptyLabel = UILabel()
    private lazy var retryButton = UIButton.sketchButton(title: "重試", systemImage: "arrow.clockwise")

    init(inventory: FoodInventoryService, compartments: @escaping () -> [Compartment],
         storageFilter: StorageFilter = .all, kindFilter: ReminderKindFilter = .all) {
        self.inventory = inventory
        self.compartments = compartments
        self.storageFilter = storageFilter
        self.kindFilter = kindFilter
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "食材提醒"
        view.backgroundColor = Theme.Color.background
        view.accessibilityIdentifier = "reminderCenter"
        let settings = UIBarButtonItem(image: UIImage(systemName: "gearshape"), primaryAction: UIAction { [weak self] _ in
            self?.onOpenSettings?()
        })
        settings.accessibilityLabel = "通知設定"
        navigationItem.rightBarButtonItem = settings
        buildLayout()
        NotificationCenter.default.addObserver(self, selector: #selector(reload), name: .foodInventoryDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(reload), name: UIApplication.significantTimeChangeNotification, object: nil)
        reload()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(false, animated: animated)
    }

    // MARK: - Data

    @objc func reload() {
        let now = Date()
        let items = inventory.items, compartments = compartments()
        let counts = builder.counts(items: items, compartments: compartments, storage: storageFilter, now: now)
        let failedWithoutData = inventory.loadState.isFailed && items.isEmpty
        for (kind, tile) in tiles {
            let count: Int? = failedWithoutData ? nil : counts[kind.reminderKind!] ?? 0
            tile.update(count: count, isSelected: kind == kindFilter)
        }
        entries = builder.entries(items: items, compartments: compartments, storage: storageFilter, kind: kindFilter, now: now)
        emptyLabel.text = failedWithoutData ? "無法讀取食材資料" : "目前沒有需要注意的食材"
        retryButton.isHidden = !failedWithoutData
        emptyView.isHidden = !entries.isEmpty
        tableView.reloadData()
    }

    func select(storage: StorageFilter) {
        storageFilter = storage
        filterControl.selectedSegmentIndex = StorageFilter.allCases.firstIndex(of: storage) ?? 0
        reload()
    }

    func select(kind: ReminderKindFilter) {
        // Tapping the active tile again shows every reminder.
        kindFilter = kind == kindFilter ? .all : kind
        reload()
    }

    // MARK: - Layout

    private func buildLayout() {
        filterControl.selectedSegmentIndex = StorageFilter.allCases.firstIndex(of: storageFilter) ?? 0
        filterControl.selectedSegmentTintColor = Theme.Color.interior
        filterControl.backgroundColor = Theme.Color.fridgeBody
        filterControl.accessibilityLabel = "儲存類型"
        filterControl.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.select(storage: StorageFilter.allCases[self.filterControl.selectedSegmentIndex])
        }, for: .valueChanged)

        let tileRow = UIStackView(arrangedSubviews: tiles.map(\.1))
        tileRow.spacing = 8
        tileRow.distribution = .fillEqually
        for (kind, tile) in tiles {
            tile.accessibilityIdentifier = "reminder.tile.\(kind)"
            tile.addAction(UIAction { [weak self] _ in self?.select(kind: kind) }, for: .touchUpInside)
        }

        let header = UIStackView(arrangedSubviews: [filterControl, tileRow])
        header.axis = .vertical
        header.spacing = 12
        header.translatesAutoresizingMaskIntoConstraints = false

        tableView.backgroundColor = .clear
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(ReminderCell.self, forCellReuseIdentifier: ReminderCell.reuseID)
        tableView.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.font = UIFont.preferredFont(forTextStyle: .body)
        emptyLabel.adjustsFontForContentSizeCategory = true
        emptyLabel.textColor = Theme.Color.textSecondary
        emptyLabel.textAlignment = .center
        emptyLabel.numberOfLines = 0
        retryButton.addAction(UIAction { [weak self] _ in self?.inventory.retryLoading() }, for: .touchUpInside)
        emptyView.addArrangedSubview(emptyLabel)
        emptyView.addArrangedSubview(retryButton)
        emptyView.axis = .vertical
        emptyView.alignment = .center
        emptyView.spacing = 12
        emptyView.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(header)
        view.addSubview(tableView)
        view.addSubview(emptyView)
        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: guide.topAnchor, constant: 8),
            header.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: Theme.Metric.gutter),
            header.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -Theme.Metric.gutter),
            tableView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 4),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            emptyView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 48),
            emptyView.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 32),
            emptyView.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -32),
        ])
    }

    // MARK: - Table

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        entries.isEmpty ? nil : (kindFilter == .all ? "需要注意的食材" : kindFilter.title)
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { entries.count }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: ReminderCell.reuseID, for: indexPath) as! ReminderCell
        cell.configure(entries[indexPath.row])
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        onOpenFood?(entries[indexPath.row].item.id)
    }
}

private extension ReminderKindFilter {
    var reminderKind: FoodReminderKind? {
        switch self {
        case .all: return nil
        case .expiringSoon: return .expiringSoon
        case .expired: return .expired
        case .storedTooLong: return .storedTooLong
        }
    }
}

/// Count tile that doubles as a filter toggle.
final class ReminderTile: UIControl {
    private let countLabel = UILabel()
    private let titleLabel = UILabel()
    private let title: String

    init(title: String) {
        self.title = title
        super.init(frame: .zero)
        layer.cornerRadius = 12
        layer.borderColor = Theme.Color.stroke.cgColor
        countLabel.font = UIFontMetrics(forTextStyle: .title1).scaledFont(for: .monospacedDigitSystemFont(ofSize: 26, weight: .light))
        countLabel.adjustsFontForContentSizeCategory = true
        countLabel.textColor = Theme.Color.textPrimary
        titleLabel.text = title
        titleLabel.font = UIFont.preferredFont(forTextStyle: .footnote)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = Theme.Color.textSecondary
        titleLabel.adjustsFontSizeToFitWidth = true
        let stack = UIStackView(arrangedSubviews: [countLabel, titleLabel])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 2
        stack.isUserInteractionEnabled = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 64),
        ])
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(count: Int?, isSelected: Bool) {
        countLabel.text = count.map(String.init) ?? "—"
        backgroundColor = isSelected ? Theme.Color.interior : Theme.Color.fridgeBody.withAlphaComponent(0.6)
        layer.borderWidth = isSelected ? 1.5 : 0
        self.isSelected = isSelected
        accessibilityLabel = "\(title) \(count.map { "\($0) 項" } ?? "無資料")"
        accessibilityTraits = isSelected ? [.button, .selected] : .button
        accessibilityHint = isSelected ? "點兩下顯示全部提醒" : "點兩下只顯示\(title)"
    }

    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.7 : 1 }
    }
}

/// One reminder row: icon, name, location, and every applicable status on the right.
final class ReminderCell: UITableViewCell {
    static let reuseID = "ReminderCell"
    private let iconView = UIImageView()
    private let nameLabel = UILabel()
    private let locationLabel = UILabel()
    private let statusLabel = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = Theme.Color.interior
        accessoryType = .disclosureIndicator
        iconView.contentMode = .scaleAspectFit
        nameLabel.font = UIFont.preferredFont(forTextStyle: .body)
        locationLabel.font = UIFont.preferredFont(forTextStyle: .footnote)
        statusLabel.font = UIFont.preferredFont(forTextStyle: .subheadline)
        for label in [nameLabel, locationLabel, statusLabel] {
            label.adjustsFontForContentSizeCategory = true
            label.numberOfLines = 0
        }
        nameLabel.textColor = Theme.Color.textPrimary
        locationLabel.textColor = Theme.Color.textSecondary
        statusLabel.textAlignment = .right
        statusLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let texts = UIStackView(arrangedSubviews: [nameLabel, locationLabel])
        texts.axis = .vertical
        texts.spacing = 2
        let row = UIStackView(arrangedSubviews: [iconView, texts, statusLabel])
        row.spacing = 12
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(row)
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 32),
            iconView.heightAnchor.constraint(equalToConstant: 32),
            row.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            row.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10),
            row.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(_ entry: ReminderEntry) {
        iconView.image = CategoryIconProvider.image(for: entry.item.categoryID, size: 32)
        nameLabel.text = entry.item.name
        locationLabel.text = entry.locationText
        statusLabel.text = entry.statusTexts.joined(separator: "\n")
        statusLabel.textColor = entry.kinds.contains(.expired) ? Theme.Color.destructive : Theme.Color.textPrimary
        accessibilityLabel = "\(entry.item.name)，\(entry.locationText)，\(entry.statusTexts.joined(separator: "，"))"
    }
}
