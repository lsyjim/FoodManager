import UIKit

/// Bottom sheet listing the active food in one compartment (normal mode only; edit mode keeps the layout sheet).
/// Starts at a medium, undimmed detent so the fridge stays visible above it.
final class FoodListSheetController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    var onAddFood: ((UUID) -> Void)?
    var onEditFood: ((UUID) -> Void)?

    private(set) var compartmentID: UUID
    private let inventory: FoodInventoryService
    private let compartments: () -> [Compartment]
    private let evaluator = FoodReminderEvaluator()
    private var items: [FoodItem] = []

    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let emptyLabel = UILabel()
    private lazy var addButton = UIButton.sketchButton(title: "新增食材", systemImage: "plus", filled: true)

    init(compartmentID: UUID, inventory: FoodInventoryService, compartments: @escaping () -> [Compartment]) {
        self.compartmentID = compartmentID
        self.inventory = inventory
        self.compartments = compartments
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .pageSheet
        if let sheet = sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.largestUndimmedDetentIdentifier = .medium
            sheet.prefersGrabberVisible = true
            sheet.preferredCornerRadius = 20
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.Color.background
        buildLayout()
        NotificationCenter.default.addObserver(self, selector: #selector(reload), name: .foodInventoryDidChange, object: nil)
        reload()
    }

    /// Re-point an already presented sheet at another compartment.
    func show(compartmentID: UUID) {
        self.compartmentID = compartmentID
        reload()
    }

    @objc func reload() {
        guard isViewLoaded else { return }
        let compartment = compartments().first { $0.id == compartmentID }
        items = inventory.items(in: compartmentID)
            .sorted { ($0.storedAt, $0.name) < ($1.storedAt, $1.name) }
        titleLabel.text = compartment?.name ?? "隔層"
        let storage = compartment.map { $0.storageType == .unspecified ? $0.parentZoneID.displayName : $0.storageType.displayName }
        subtitleLabel.text = [storage, "\(items.count) 項"].compactMap { $0 }.joined(separator: " · ")
        emptyLabel.isHidden = !items.isEmpty
        tableView.reloadData()
    }

    private func buildLayout() {
        titleLabel.font = Theme.Font.title
        titleLabel.textColor = Theme.Color.textPrimary
        subtitleLabel.font = Theme.Font.caption
        subtitleLabel.textColor = Theme.Color.textSecondary
        addButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.onAddFood?(self.compartmentID)
        }, for: .touchUpInside)

        let titles = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
        titles.axis = .vertical
        titles.spacing = 2
        let header = UIStackView(arrangedSubviews: [titles, UIView(), addButton])
        header.alignment = .center
        header.translatesAutoresizingMaskIntoConstraints = false

        tableView.backgroundColor = .clear
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(FoodItemCell.self, forCellReuseIdentifier: FoodItemCell.reuseID)
        tableView.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.text = "這裡還沒有食材"
        emptyLabel.font = Theme.Font.body
        emptyLabel.textColor = Theme.Color.textSecondary
        emptyLabel.textAlignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(header)
        view.addSubview(tableView)
        view.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.topAnchor, constant: 22),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Theme.Metric.gutter),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Theme.Metric.gutter),
            tableView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 4),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            emptyLabel.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 40),
            emptyLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
        ])
    }

    // MARK: - Table

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { items.count }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: FoodItemCell.reuseID, for: indexPath) as! FoodItemCell
        let item = items[indexPath.row]
        cell.configure(item, location: nil, showsQuantityControls: true, evaluator: evaluator, now: Date())
        cell.onIncrement = { [weak self] in self?.adjust(item, by: 1) }
        cell.onDecrement = { [weak self] in self?.adjust(item, by: -1) }
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        onEditFood?(items[indexPath.row].id)
    }

    func tableView(_ tableView: UITableView,
                   trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        let item = items[indexPath.row]
        let consumed = UIContextualAction(style: .normal, title: "已食用") { [weak self] _, _, done in
            guard let self else { return done(false) }
            FoodActions.perform(on: self) { try self.inventory.markConsumed(item.id) }
            done(true)
        }
        consumed.backgroundColor = Theme.Color.stroke
        let move = UIContextualAction(style: .normal, title: "移動") { [weak self] _, _, done in
            guard let self else { return done(false) }
            FoodActions.presentMove(item, inventory: self.inventory, compartments: self.compartments(), from: self,
                                    sourceView: tableView.cellForRow(at: indexPath))
            done(true)
        }
        move.backgroundColor = Theme.Color.divider
        return UISwipeActionsConfiguration(actions: [consumed, move])
    }

    private func adjust(_ item: FoodItem, by delta: Decimal) {
        do {
            try inventory.adjustQuantity(item.id, by: delta)
        } catch FoodValidationError.zeroQuantity {
            FoodActions.confirmConsumed(item, inventory: inventory, from: self)
        } catch {
            FoodActions.showError("無法更新數量", on: self)
        }
    }
}
