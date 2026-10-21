import UIKit

/// Local name search across all active food. An empty query lists everything (including food whose
/// compartment no longer exists, so nothing can silently disappear). Selecting a result opens its editor.
final class FoodSearchViewController: UITableViewController, UISearchResultsUpdating {
    /// `.unplaced` lists only food whose compartment no longer exists, so it can be reassigned by hand.
    enum Scope { case all, unplaced }

    private let scope: Scope
    private let inventory: FoodInventoryService
    private let compartments: () -> [Compartment]
    private let evaluator = FoodReminderEvaluator()
    private let searchController = UISearchController(searchResultsController: nil)
    private var results: [FoodItem] = []
    private let emptyLabel = UILabel()

    init(scope: Scope = .all, inventory: FoodInventoryService, compartments: @escaping () -> [Compartment]) {
        self.scope = scope
        self.inventory = inventory
        self.compartments = compartments
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    static func present(scope: Scope = .all, inventory: FoodInventoryService, compartments: @escaping () -> [Compartment],
                        from presenter: UIViewController) {
        let navigation = UINavigationController(rootViewController: FoodSearchViewController(scope: scope, inventory: inventory,
                                                                                             compartments: compartments))
        navigation.modalPresentationStyle = .pageSheet
        presenter.present(navigation, animated: true)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = scope == .all ? "搜尋食材" : "需要重新放置"
        view.backgroundColor = Theme.Color.background
        tableView.backgroundColor = Theme.Color.background
        tableView.register(FoodItemCell.self, forCellReuseIdentifier: FoodItemCell.reuseID)
        tableView.keyboardDismissMode = .onDrag
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "完成", primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        })
        searchController.searchResultsUpdater = self
        searchController.obscuresBackgroundDuringPresentation = false
        searchController.searchBar.placeholder = "輸入食材名稱"
        navigationItem.searchController = searchController
        navigationItem.hidesSearchBarWhenScrolling = false

        emptyLabel.font = Theme.Font.body
        emptyLabel.textColor = Theme.Color.textSecondary
        emptyLabel.textAlignment = .center
        tableView.backgroundView = emptyLabel

        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: .foodInventoryDidChange, object: nil)
        refresh()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        searchController.searchBar.becomeFirstResponder()
    }

    func updateSearchResults(for searchController: UISearchController) { refresh() }

    @objc private func refresh() {
        let query = searchController.searchBar.text ?? ""
        results = inventory.search(query)
        if scope == .unplaced {
            let missing = Set(inventory.itemsWithMissingCompartment.map(\.id))
            results = results.filter { missing.contains($0.id) }
        }
        if inventory.loadState.isFailed {
            emptyLabel.text = results.isEmpty ? "無法讀取食材資料" : nil
        } else if scope == .unplaced {
            emptyLabel.text = results.isEmpty ? "所有食材都已放回冰箱" : nil
        } else {
            emptyLabel.text = results.isEmpty ? (query.isEmpty ? "冰箱裡還沒有食材" : "找不到「\(query)」") : nil
        }
        tableView.reloadData()
    }

    private func location(of item: FoodItem) -> String {
        guard let compartment = compartments().first(where: { $0.id == item.compartmentID }) else { return "位置不存在" }
        return CompartmentNaming.locationWithStorage(compartment)
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { results.count }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: FoodItemCell.reuseID, for: indexPath) as! FoodItemCell
        let item = results[indexPath.row]
        cell.configure(item, location: location(of: item), showsQuantityControls: false, evaluator: evaluator, now: Date())
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        FoodEditorViewController.present(.edit(foodID: results[indexPath.row].id), inventory: inventory,
                                         compartments: compartments(), from: self)
    }
}
