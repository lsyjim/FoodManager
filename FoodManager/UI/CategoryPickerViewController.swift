import UIKit

/// Compact category picker: search field, pinned favorites (in pin order), then all remaining categories
/// in catalog order. Long-press a category to pin or unpin it. Tapping a category selects it.
final class CategoryPickerViewController: UIViewController, UICollectionViewDelegate, UISearchResultsUpdating {
    private enum Section { case favorites, others }

    var onSelect: ((String) -> Void)?

    private let store: FavoriteCategoryStore
    private var favorites: FavoriteCategories
    private var selectedID: String
    private var query = ""
    private let searchController = UISearchController(searchResultsController: nil)
    private lazy var collectionView = UICollectionView(frame: .zero, collectionViewLayout: makeLayout())
    private var dataSource: UICollectionViewDiffableDataSource<Section, String>!
    private let emptyLabel = UILabel()

    init(selectedID: String, store: FavoriteCategoryStore) {
        self.store = store
        self.selectedID = selectedID
        favorites = store.load()
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "選擇食材分類"
        view.backgroundColor = Theme.Color.background

        searchController.searchResultsUpdater = self
        searchController.obscuresBackgroundDuringPresentation = false
        searchController.searchBar.placeholder = "搜尋分類"
        navigationItem.searchController = searchController
        navigationItem.hidesSearchBarWhenScrolling = false

        collectionView.backgroundColor = .clear
        collectionView.delegate = self
        collectionView.keyboardDismissMode = .onDrag
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        emptyLabel.text = "找不到符合的分類"
        emptyLabel.font = Theme.Font.body
        emptyLabel.textColor = Theme.Color.textSecondary
        emptyLabel.textAlignment = .center
        collectionView.backgroundView = emptyLabel

        configureDataSource()
        applySnapshot(animated: false)
    }

    // MARK: - Data

    private func configureDataSource() {
        let cellRegistration = UICollectionView.CellRegistration<CategoryCell, String> { [weak self] cell, indexPath, id in
            guard let self else { return }
            cell.configure(FoodCategoryCatalog.category(id: id), isSelected: id == self.selectedID,
                           isFavorite: self.dataSource.sectionIdentifier(for: indexPath.section) == .favorites)
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, id in
            collectionView.dequeueConfiguredReusableCell(using: cellRegistration, for: indexPath, item: id)
        }
        let headerRegistration = UICollectionView.SupplementaryRegistration<CategoryHeaderView>(
            elementKind: UICollectionView.elementKindSectionHeader) { [weak self] header, _, indexPath in
            guard let self else { return }
            let isFavorites = self.dataSource.sectionIdentifier(for: indexPath.section) == .favorites
            let hasFavorites = !self.favorites.ids.isEmpty
            header.configure(title: isFavorites ? "常用分類" : (hasFavorites ? "其他分類" : "全部分類"),
                             systemImage: isFavorites ? "pin" : nil,
                             hint: isFavorites || hasFavorites ? nil : "長按分類可釘選為常用（最多 \(FavoriteCategories.maxCount) 個）")
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: headerRegistration, for: indexPath)
        }
    }

    private func applySnapshot(animated: Bool) {
        let sections = CategoryPickerSections(favorites: favorites, query: query)
        var snapshot = NSDiffableDataSourceSnapshot<Section, String>()
        if !sections.favorites.isEmpty {
            snapshot.appendSections([.favorites])
            snapshot.appendItems(sections.favorites.map(\.id), toSection: .favorites)
        }
        if !sections.others.isEmpty {
            snapshot.appendSections([.others])
            snapshot.appendItems(sections.others.map(\.id), toSection: .others)
        }
        // Section membership changes cell styles and header titles, so reload whole sections (20 items: cheap).
        snapshot.reloadSections(snapshot.sectionIdentifiers)
        emptyLabel.isHidden = !sections.isEmpty
        dataSource.apply(snapshot, animatingDifferences: animated)
    }

    func updateSearchResults(for searchController: UISearchController) {
        query = searchController.searchBar.text ?? ""
        applySnapshot(animated: false)
    }

    // MARK: - Favorites

    private func togglePin(_ id: String) {
        if favorites.contains(id) {
            favorites.unpin(id)
        } else {
            do {
                try favorites.pin(id)
            } catch let error as FavoriteCategoryError {
                return FoodActions.showError(error.message, on: self)
            } catch {
                return
            }
        }
        store.save(favorites)
        applySnapshot(animated: true)
    }

    // MARK: - UICollectionViewDelegate

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let id = dataSource.itemIdentifier(for: indexPath) else { return }
        selectedID = id
        onSelect?(id)
    }

    func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
                        point: CGPoint) -> UIContextMenuConfiguration? {
        guard let indexPath = indexPaths.first, let id = dataSource.itemIdentifier(for: indexPath) else { return nil }
        let isPinned = favorites.contains(id)
        return UIContextMenuConfiguration(actionProvider: { [weak self] _ in
            let action = UIAction(title: isPinned ? "取消釘選" : "釘選為常用",
                                  image: UIImage(systemName: isPinned ? "pin.slash" : "pin")) { _ in self?.togglePin(id) }
            if !isPinned, let self, self.favorites.ids.count >= FavoriteCategories.maxCount {
                action.attributes = .disabled
                action.subtitle = "常用分類最多 \(FavoriteCategories.maxCount) 個"
            }
            return UIMenu(children: [action])
        })
    }

    // MARK: - Layout

    private func makeLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { _, environment in
            let columns = environment.container.effectiveContentSize.width > 500 ? 6 : 4
            let item = NSCollectionLayoutItem(layoutSize: NSCollectionLayoutSize(
                widthDimension: .fractionalWidth(1.0 / CGFloat(columns)), heightDimension: .absolute(78)))
            item.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4)
            let group = NSCollectionLayoutGroup.horizontal(layoutSize: NSCollectionLayoutSize(
                widthDimension: .fractionalWidth(1), heightDimension: .absolute(78)), subitems: [item])
            let section = NSCollectionLayoutSection(group: group)
            section.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 16, bottom: 16, trailing: 16)
            let header = NSCollectionLayoutBoundarySupplementaryItem(
                layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(36)),
                elementKind: UICollectionView.elementKindSectionHeader, alignment: .top)
            section.boundarySupplementaryItems = [header]
            return section
        }
    }
}

/// One category tile: illustration (or placeholder) above the name.
final class CategoryCell: UICollectionViewCell {
    private let imageView = UIImageView()
    private let nameLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        imageView.contentMode = .scaleAspectFit
        nameLabel.font = UIFont.systemFont(ofSize: 12, weight: .medium)
        nameLabel.textColor = Theme.Color.textPrimary
        nameLabel.textAlignment = .center
        nameLabel.adjustsFontSizeToFitWidth = true
        nameLabel.minimumScaleFactor = 0.8
        let stack = UIStackView(arrangedSubviews: [imageView, nameLabel])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        contentView.layer.cornerRadius = 12
        NSLayoutConstraint.activate([
            imageView.widthAnchor.constraint(equalToConstant: 30),
            imageView.heightAnchor.constraint(equalToConstant: 30),
            stack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -4),
        ])
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(_ category: FoodCategory, isSelected: Bool, isFavorite: Bool) {
        imageView.image = CategoryIconProvider.image(for: category.id, size: 30)
        nameLabel.text = category.displayName
        // Favorites sit on soft tiles; the current choice gets a thin dark outline.
        contentView.backgroundColor = isFavorite ? Theme.Color.fridgeBody.withAlphaComponent(0.7) : .clear
        contentView.layer.borderWidth = isSelected ? 1.5 : 0
        contentView.layer.borderColor = Theme.Color.stroke.cgColor
        accessibilityLabel = category.displayName
        accessibilityValue = [isSelected ? "已選取" : nil, isFavorite ? "常用" : nil].compactMap { $0 }.joined(separator: "，")
        accessibilityHint = "長按可\(isFavorite ? "取消釘選" : "釘選為常用")"
    }
}

final class CategoryHeaderView: UICollectionReusableView {
    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let hintLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        iconView.tintColor = Theme.Color.textPrimary
        iconView.contentMode = .scaleAspectFit
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        titleLabel.font = UIFont.systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = Theme.Color.textPrimary
        hintLabel.font = Theme.Font.caption
        hintLabel.textColor = Theme.Color.textSecondary
        hintLabel.numberOfLines = 0
        let titleRow = UIStackView(arrangedSubviews: [iconView, titleLabel])
        titleRow.spacing = 6
        let stack = UIStackView(arrangedSubviews: [titleRow, hintLabel])
        stack.axis = .vertical
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(title: String, systemImage: String?, hint: String?) {
        titleLabel.text = title
        iconView.image = systemImage.flatMap { UIImage(systemName: $0) }
        iconView.isHidden = systemImage == nil
        hintLabel.text = hint
        hintLabel.isHidden = hint == nil
    }
}
