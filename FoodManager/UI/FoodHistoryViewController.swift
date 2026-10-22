import UIKit

/// Consumed food (newest first) with search, lightweight statistics, restore, pin-as-favorite and
/// explicit permanent delete. Consumed food never appears in the fridge, counts or reminders.
final class FoodHistoryViewController: UITableViewController, UISearchResultsUpdating {
    private let inventory: FoodInventoryService
    private let compartments: () -> [Compartment]
    private let favoriteStore: FavoriteFoodStore
    private let searchController = UISearchController(searchResultsController: nil)
    private(set) var results: [FoodItem] = []
    private(set) var loadFailed = false
    private let statsLabel = UILabel()
    private let emptyView = UIStackView()
    private let emptyLabel = UILabel()
    private lazy var retryButton = UIButton.sketchButton(title: "重試", systemImage: "arrow.clockwise")

    init(inventory: FoodInventoryService, compartments: @escaping () -> [Compartment],
         favoriteStore: FavoriteFoodStore = UserDefaultsFavoriteFoodStore()) {
        self.inventory = inventory
        self.compartments = compartments
        self.favoriteStore = favoriteStore
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "食用紀錄"
        view.accessibilityIdentifier = "history"
        tableView.backgroundColor = Theme.Color.background
        tableView.register(HistoryCell.self, forCellReuseIdentifier: HistoryCell.reuseID)
        tableView.keyboardDismissMode = .onDrag
        searchController.searchResultsUpdater = self
        searchController.obscuresBackgroundDuringPresentation = false
        searchController.searchBar.placeholder = "搜尋食用紀錄"
        navigationItem.searchController = searchController
        navigationItem.hidesSearchBarWhenScrolling = false

        statsLabel.font = UIFont.preferredFont(forTextStyle: .footnote)
        statsLabel.adjustsFontForContentSizeCategory = true
        statsLabel.textColor = Theme.Color.textSecondary
        statsLabel.numberOfLines = 0

        emptyLabel.font = UIFont.preferredFont(forTextStyle: .body)
        emptyLabel.adjustsFontForContentSizeCategory = true
        emptyLabel.textColor = Theme.Color.textSecondary
        emptyLabel.textAlignment = .center
        emptyLabel.numberOfLines = 0
        retryButton.addAction(UIAction { [weak self] _ in self?.reload() }, for: .touchUpInside)
        emptyView.addArrangedSubview(emptyLabel)
        emptyView.addArrangedSubview(retryButton)
        emptyView.axis = .vertical
        emptyView.alignment = .center
        emptyView.spacing = 12
        let background = UIView()
        emptyView.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(emptyView)
        NSLayoutConstraint.activate([
            emptyView.centerXAnchor.constraint(equalTo: background.centerXAnchor),
            emptyView.centerYAnchor.constraint(equalTo: background.centerYAnchor, constant: -60),
            emptyView.leadingAnchor.constraint(greaterThanOrEqualTo: background.leadingAnchor, constant: 32),
        ])
        tableView.backgroundView = background

        NotificationCenter.default.addObserver(self, selector: #selector(reload), name: .foodInventoryDidChange, object: nil)
        reload()
    }

    func updateSearchResults(for searchController: UISearchController) { reload() }

    @objc func reload() {
        let query = searchController.searchBar.text ?? ""
        do {
            let history = try inventory.historyItems()
            results = query.trimmingCharacters(in: .whitespaces).isEmpty
                ? history : history.filter { $0.name.localizedStandardContains(query.trimmingCharacters(in: .whitespaces)) }
            loadFailed = false
            statsLabel.text = Self.statisticsText(HistoryStatistics(history: history))
            emptyLabel.text = history.isEmpty ? "還沒有食用紀錄\n標記為「已食用」的食材會出現在這裡" : "找不到「\(query)」"
        } catch {
            // Keep what is on screen; never present a failed read as "no history".
            loadFailed = true
            emptyLabel.text = "無法讀取食用紀錄"
        }
        retryButton.isHidden = !loadFailed
        emptyView.isHidden = !results.isEmpty
        tableView.reloadData()
    }

    static func statisticsText(_ stats: HistoryStatistics) -> String? {
        guard stats.consumedCount > 0 else { return nil }
        var parts = ["共 \(stats.consumedCount) 筆已食用"]
        if let average = stats.averageStorageDays {
            let rounded = (average * 10).rounded() / 10
            let text = rounded == rounded.rounded() ? "\(Int(rounded))" : String(format: "%.1f", rounded)
            parts.append("平均存放 \(text) 天")
        }
        if !stats.topNames.isEmpty {
            parts.append("最常吃：" + stats.topNames.map { "\($0.name)（\($0.count)）" }.joined(separator: "、"))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Table

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { results.count }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        results.isEmpty ? nil : statsLabel.text
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: HistoryCell.reuseID, for: indexPath) as! HistoryCell
        let item = results[indexPath.row]
        cell.configure(item, location: compartments().first { $0.id == item.compartmentID })
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let item = results[indexPath.row]
        let sheet = UIAlertController(title: item.name, message: nil, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "放回冰箱", style: .default) { [weak self] _ in self?.restore(item) })
        sheet.addAction(UIAlertAction(title: "加入常用食材", style: .default) { [weak self] _ in self?.pinFavorite(item) })
        sheet.addAction(UIAlertAction(title: "永久刪除", style: .destructive) { [weak self] _ in self?.confirmDelete(item) })
        sheet.addAction(UIAlertAction(title: "取消", style: .cancel))
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = tableView.cellForRow(at: indexPath)
        }
        present(sheet, animated: true)
    }

    override func tableView(_ tableView: UITableView,
                            trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        let item = results[indexPath.row]
        let delete = UIContextualAction(style: .destructive, title: "永久刪除") { [weak self] _, _, done in
            self?.confirmDelete(item)
            done(false) // the row disappears only after a confirmed, successful delete
        }
        let restore = UIContextualAction(style: .normal, title: "放回冰箱") { [weak self] _, _, done in
            self?.restore(item)
            done(true)
        }
        restore.backgroundColor = Theme.Color.stroke
        return UISwipeActionsConfiguration(actions: [delete, restore])
    }

    // MARK: - Actions

    /// Restores to the original compartment, or asks for a destination if it no longer exists.
    func restore(_ item: FoodItem, to destination: UUID? = nil) {
        do {
            let restored = try inventory.restore(item.id, to: destination)
            let place = compartments().first { $0.id == restored.compartmentID }.map(CompartmentNaming.location) ?? ""
            ToastView.show("已放回 \(place)", in: view)
        } catch FoodValidationError.restoreNeedsCompartment {
            chooseDestination(for: item)
        } catch let error as FoodValidationError {
            FoodActions.showError(error.message, on: self)
        } catch {
            FoodActions.showError("無法放回冰箱，資料沒有變更。請再試一次。", on: self)
        }
    }

    private func chooseDestination(for item: FoodItem) {
        let sheet = UIAlertController(title: "選擇放回的位置", message: "「\(item.name)」原本的隔層已不存在", preferredStyle: .actionSheet)
        for compartment in compartments() {
            sheet.addAction(UIAlertAction(title: CompartmentNaming.locationWithStorage(compartment), style: .default) { [weak self] _ in
                self?.restore(item, to: compartment.id)
            })
        }
        sheet.addAction(UIAlertAction(title: "取消", style: .cancel))
        sheet.popoverPresentationController?.sourceView = view
        present(sheet, animated: true)
    }

    private func pinFavorite(_ item: FoodItem) {
        var favorites = favoriteStore.load()
        let valid = compartments().contains { $0.id == item.compartmentID }
        do {
            try favorites.pin(FoodTemplate(name: item.name, categoryID: item.categoryID, unit: item.unit,
                                           preferredCompartmentID: valid ? item.compartmentID : nil))
            favoriteStore.save(favorites)
            ToastView.show("已加入常用食材", in: view)
        } catch let error as FavoriteFoodError {
            FoodActions.showError(error.message, on: self)
        } catch {}
    }

    private func confirmDelete(_ item: FoodItem) {
        let alert = UIAlertController(title: "永久刪除「\(item.name)」？",
                                      message: "這筆紀錄會從食用紀錄中移除，無法復原。", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "永久刪除", style: .destructive) { [weak self] _ in
            guard let self else { return }
            // The list refreshes from the change notification, i.e. only after the delete succeeded.
            FoodActions.perform(on: self) { try self.inventory.delete(item.id) }
        })
        present(alert, animated: true)
    }
}

final class HistoryCell: UITableViewCell {
    static let reuseID = "HistoryCell"
    private let iconView = UIImageView()
    private let nameLabel = UILabel()
    private let quantityLabel = UILabel()
    private let detailLabel = UILabel()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("Md")
        return formatter
    }()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = Theme.Color.interior
        iconView.contentMode = .scaleAspectFit
        nameLabel.font = UIFont.preferredFont(forTextStyle: .body)
        quantityLabel.font = UIFont.preferredFont(forTextStyle: .body)
        detailLabel.font = UIFont.preferredFont(forTextStyle: .footnote)
        for label in [nameLabel, quantityLabel, detailLabel] { label.adjustsFontForContentSizeCategory = true }
        nameLabel.numberOfLines = 0
        detailLabel.numberOfLines = 0
        nameLabel.textColor = Theme.Color.textPrimary
        quantityLabel.textColor = Theme.Color.textPrimary
        detailLabel.textColor = Theme.Color.textSecondary
        quantityLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        quantityLabel.setContentHuggingPriority(.required, for: .horizontal)

        let titleRow = UIStackView(arrangedSubviews: [nameLabel, quantityLabel])
        titleRow.spacing = 8
        titleRow.alignment = .firstBaseline
        let texts = UIStackView(arrangedSubviews: [titleRow, detailLabel])
        texts.axis = .vertical
        texts.spacing = 3
        let row = UIStackView(arrangedSubviews: [iconView, texts])
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
            row.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(_ item: FoodItem, location: Compartment?) {
        iconView.image = CategoryIconProvider.image(for: item.categoryID, size: 32)
        nameLabel.text = item.name
        quantityLabel.text = FoodFormatting.quantityText(item.quantity, unit: item.unit)
        let place = location.map(CompartmentNaming.location) ?? "原隔層已不存在"
        let stored = Self.dateFormatter.string(from: item.storedAt)
        let consumed = item.consumedAt.map(Self.dateFormatter.string(from:)) ?? "—"
        let days = item.consumedAt.map { FoodDateCalculator().daysStored(since: item.storedAt, now: $0) } ?? 0
        detailLabel.text = "\(place)\n放入 \(stored) · 食用 \(consumed) · 存放 \(days) 天"
        accessibilityLabel = "\(item.name)，\(quantityLabel.text ?? "")，\(detailLabel.text ?? "")"
        accessibilityHint = "點兩下可放回冰箱、加入常用或永久刪除"
    }
}

/// Small transient confirmation message at the bottom of a view.
enum ToastView {
    /// `bottomInset` lifts the message above bottom controls (e.g. the fridge's action bar).
    static func show(_ message: String, in host: UIView, bottomInset: CGFloat = 24) {
        let label = PaddedLabel()
        label.text = message
        label.font = UIFont.preferredFont(forTextStyle: .footnote)
        label.textColor = Theme.Color.interior
        label.backgroundColor = Theme.Color.stroke.withAlphaComponent(0.92)
        label.layer.cornerRadius = 14
        label.clipsToBounds = true
        label.numberOfLines = 0
        label.textAlignment = .center
        label.alpha = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            label.bottomAnchor.constraint(equalTo: host.safeAreaLayoutGuide.bottomAnchor, constant: -bottomInset),
            label.widthAnchor.constraint(lessThanOrEqualTo: host.widthAnchor, constant: -48),
        ])
        UIAccessibility.post(notification: .announcement, argument: message)
        UIView.animate(withDuration: 0.2) { label.alpha = 1 } completion: { _ in
            UIView.animate(withDuration: 0.3, delay: 1.6) { label.alpha = 0 } completion: { _ in label.removeFromSuperview() }
        }
    }

    private final class PaddedLabel: UILabel {
        override func drawText(in rect: CGRect) { super.drawText(in: rect.insetBy(dx: 14, dy: 8)) }
        override var intrinsicContentSize: CGSize {
            let size = super.intrinsicContentSize
            return CGSize(width: size.width + 28, height: size.height + 16)
        }
    }
}
