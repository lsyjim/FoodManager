import PhotosUI
import UIKit
import UniformTypeIdentifiers

/// 裝飾冰箱: edits one fridge's magnets on a draft. The door can't be opened here; nothing is stored until
/// 儲存 succeeds, and 取消 restores the arrangement from before editing exactly.
final class MagnetEditorViewController: UIViewController, PHPickerViewControllerDelegate {
    private let fridge: Fridge
    private let template: FridgeTemplate
    private let library: MagnetLibrary
    private var draft: MagnetDraft
    /// Called after a successful save.
    var onSaved: (() -> Void)?

    private let artwork = UIImageView()
    private let board: MagnetBoardView
    private let hintLabel = UILabel()
    private lazy var cancelButton = UIButton.sketchButton(title: "取消")
    private lazy var saveButton = UIButton.sketchButton(title: "儲存", filled: true)
    private lazy var addButton = UIButton.sketchButton(title: "加入磁鐵", systemImage: "plus", filled: false)
    private lazy var styleButton = Self.toolButton("造型", "wand.and.stars", id: "magnets.style")
    private lazy var duplicateButton = Self.toolButton("複製", "plus.square.on.square", id: "magnets.duplicate")
    private lazy var forwardButton = Self.toolButton("上移", "square.2.layers.3d.top.filled", id: "magnets.forward")
    private lazy var backwardButton = Self.toolButton("下移", "square.2.layers.3d.bottom.filled", id: "magnets.backward")
    private lazy var deleteButton = Self.toolButton("刪除", "trash", id: "magnets.delete")
    private let spinner = UIActivityIndicatorView(style: .medium)

    init(fridge: Fridge, library: MagnetLibrary, magnets: [FridgeMagnet]) {
        self.fridge = fridge
        self.library = library
        template = FridgeTemplateCatalog.template(id: fridge.templateID)
        draft = MagnetDraft(fridgeID: fridge.id, magnets: magnets)
        board = MagnetBoardView(template: template, library: library)
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
        isModalInPresentation = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var currentDraft: MagnetDraft { draft }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.Color.background
        view.accessibilityIdentifier = "magnets.editor"
        buildLayout()
        wireBoard()
        board.setMode(.edit)
        board.render(draft.magnets)
        updateControls()
    }

    // MARK: Layout

    private func buildLayout() {
        let title = UILabel()
        title.text = "裝飾冰箱"
        title.font = UIFont.systemFont(ofSize: 18, weight: .semibold)
        title.textColor = Theme.Color.textPrimary
        let subtitle = UILabel()
        subtitle.text = fridge.name
        subtitle.font = Theme.Font.caption
        subtitle.textColor = Theme.Color.textSecondary
        let titles = UIStackView(arrangedSubviews: [title, subtitle])
        titles.axis = .vertical
        titles.alignment = .center
        titles.spacing = 1
        titles.layoutMargins = UIEdgeInsets(top: 0, left: 0, bottom: 2, right: 0)
        titles.isLayoutMarginsRelativeArrangement = true
        titles.setContentCompressionResistancePriority(.required, for: .vertical)
        cancelButton.accessibilityIdentifier = "magnets.cancel"
        saveButton.accessibilityIdentifier = "magnets.save"
        let header = UIStackView(arrangedSubviews: [cancelButton, titles, saveButton])
        header.alignment = .center
        header.setContentCompressionResistancePriority(.required, for: .vertical)
        header.distribution = .equalCentering

        artwork.image = FridgeArtwork.closedImage(for: template)
        artwork.contentMode = .scaleAspectFit
        let canvas = UIView()
        for subview in [artwork, board] as [UIView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            canvas.addSubview(subview)
        }

        hintLabel.font = Theme.Font.caption
        hintLabel.textColor = Theme.Color.textSecondary
        hintLabel.textAlignment = .center
        hintLabel.numberOfLines = 0
        hintLabel.adjustsFontForContentSizeCategory = true
        hintLabel.setContentCompressionResistancePriority(.required, for: .vertical)

        addButton.showsMenuAsPrimaryAction = true
        addButton.menu = UIMenu(children: [
            UIAction(title: "內建磁鐵", image: UIImage(systemName: "sparkles")) { [weak self] _ in self?.showCatalog() },
            UIAction(title: "從照片加入", image: UIImage(systemName: "photo")) { [weak self] _ in self?.showPhotoPicker() },
        ])
        addButton.accessibilityIdentifier = "magnets.add"
        let tools = UIStackView(arrangedSubviews: [styleButton, duplicateButton, forwardButton, backwardButton, deleteButton])
        tools.distribution = .fillEqually
        tools.spacing = 4
        let footer = UIStackView(arrangedSubviews: [hintLabel, tools, addButton])
        footer.axis = .vertical
        footer.spacing = 10
        footer.setContentCompressionResistancePriority(.required, for: .vertical)

        for subview in [header, canvas, footer, spinner] as [UIView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
        let guide = view.safeAreaLayoutGuide
        let artworkAspect = template.closedImageSize.width / template.closedImageSize.height
        let preferredHeight = artwork.heightAnchor.constraint(equalTo: canvas.heightAnchor)
        preferredHeight.priority = .defaultLow
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: guide.topAnchor, constant: 8),
            header.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: Theme.Metric.gutter),
            header.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -Theme.Metric.gutter),

            canvas.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 16),
            canvas.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: Theme.Metric.gutter),
            canvas.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -Theme.Metric.gutter),
            canvas.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -16),

            // The artwork keeps its aspect ratio and fills the canvas as far as it can; the board matches it exactly.
            artwork.centerXAnchor.constraint(equalTo: canvas.centerXAnchor),
            artwork.centerYAnchor.constraint(equalTo: canvas.centerYAnchor),
            artwork.widthAnchor.constraint(equalTo: artwork.heightAnchor, multiplier: artworkAspect),
            artwork.heightAnchor.constraint(lessThanOrEqualTo: canvas.heightAnchor),
            artwork.widthAnchor.constraint(lessThanOrEqualTo: canvas.widthAnchor),
            preferredHeight,
            board.topAnchor.constraint(equalTo: artwork.topAnchor),
            board.leadingAnchor.constraint(equalTo: artwork.leadingAnchor),
            board.trailingAnchor.constraint(equalTo: artwork.trailingAnchor),
            board.bottomAnchor.constraint(equalTo: artwork.bottomAnchor),

            footer.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: Theme.Metric.gutter),
            footer.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -Theme.Metric.gutter),
            footer.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -8),

            spinner.centerXAnchor.constraint(equalTo: canvas.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: canvas.centerYAnchor),
        ])

        cancelButton.addAction(UIAction { [weak self] _ in self?.cancel() }, for: .touchUpInside)
        saveButton.addAction(UIAction { [weak self] _ in self?.save() }, for: .touchUpInside)
        styleButton.addAction(UIAction { [weak self] _ in
            if let id = self?.board.selectedID { self?.cycleStyle(id) }
        }, for: .touchUpInside)
        duplicateButton.addAction(UIAction { [weak self] _ in self?.duplicateSelected() }, for: .touchUpInside)
        forwardButton.addAction(UIAction { [weak self] _ in self?.reorder(forward: true) }, for: .touchUpInside)
        backwardButton.addAction(UIAction { [weak self] _ in self?.reorder(forward: false) }, for: .touchUpInside)
        deleteButton.addAction(UIAction { [weak self] _ in self?.deleteSelected() }, for: .touchUpInside)
    }

    private static func toolButton(_ title: String, _ symbol: String, id: String) -> UIButton {
        var config = UIButton.Configuration.plain()
        config.title = title
        config.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .regular))
        config.imagePlacement = .top
        config.imagePadding = 4
        config.baseForegroundColor = Theme.Color.stroke
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var a = attributes
            a.font = UIFont.preferredFont(forTextStyle: .caption1)
            return a
        }
        let button = UIButton(configuration: config)
        button.accessibilityIdentifier = id
        button.accessibilityLabel = ["magnets.forward": "上移一層", "magnets.backward": "下移一層"][id] ?? title
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: Theme.Metric.minTouchTarget).isActive = true
        return button
    }

    // MARK: Board

    private func wireBoard() {
        board.onSelect = { [weak self] _ in self?.updateControls() }
        board.onMove = { [weak self] id, dx, dy in
            self?.draft.move(id, dx: dx, dy: dy)
            self?.refresh(id)
        }
        board.onScale = { [weak self] id, factor in
            self?.draft.scale(id, by: factor)
            self?.refresh(id)
        }
        board.onRotate = { [weak self] id, radians in
            self?.draft.rotate(id, by: radians)
            self?.refresh(id)
        }
        board.onGestureEnded = { [weak self] in self?.updateControls() }
        board.onCycleStyle = { [weak self] id in self?.cycleStyle(id) }
        board.onAccessibilityAction = { [weak self] id, action in self?.perform(action, on: id) }
    }

    private func refresh(_ id: UUID) {
        if let magnet = draft.magnet(id) { board.update(magnet) }
    }

    private func perform(_ action: MagnetAccessibilityAction, on id: UUID) {
        switch action {
        case .nextStyle:
            cycleStyle(id)
            return
        case .moveUp: draft.move(id, dx: 0, dy: -0.05)
        case .moveDown: draft.move(id, dx: 0, dy: 0.05)
        case .moveLeft: draft.move(id, dx: -0.05, dy: 0)
        case .moveRight: draft.move(id, dx: 0.05, dy: 0)
        case .enlarge: draft.scale(id, by: 1.15)
        case .shrink: draft.scale(id, by: 1 / 1.15)
        case .rotateRight: draft.rotate(id, by: .pi / 12)
        case .rotateLeft: draft.rotate(id, by: -.pi / 12)
        }
        refresh(id)
        updateControls()
    }

    private func updateControls() {
        let hasSelection = board.selectedID != nil
        for button in [styleButton, duplicateButton, forwardButton, backwardButton, deleteButton] { button.isEnabled = hasSelection }
        if let id = board.selectedID, let index = draft.magnets.firstIndex(where: { $0.id == id }) {
            forwardButton.isEnabled = index < draft.magnets.count - 1
            backwardButton.isEnabled = index > 0
            duplicateButton.isEnabled = draft.canAdd
        }
        addButton.isEnabled = draft.canAdd
        hintLabel.text = draft.magnets.isEmpty
            ? "按「加入磁鐵」選擇內建圖案或你的照片"
            : hasSelection ? "再點一下換造型・拖曳移動・雙指縮放與旋轉" : "點一下磁鐵來選取"
    }

    // MARK: Actions

    /// 原始形狀 → 拍立得 → 白框 → 圓角白框 → 郵票花邊 → 圓形 → 星星 → …
    func cycleStyle(_ id: UUID) {
        guard let magnet = draft.magnet(id) else { return }
        let next = magnet.style.next
        let image = library.image(for: magnet)
        let aspect = image.map { Double($0.size.height / max($0.size.width, 1)) } ?? 1
        draft.setStyle(id, next, imageAspect: aspect, doorAspect: template.closedDoorAspect)
        refresh(id)
        hintLabel.text = next.title
        UIAccessibility.post(notification: .announcement, argument: next.title)
    }

    private func duplicateSelected() {
        guard let id = board.selectedID, let copy = draft.duplicate(id) else { return }
        board.render(draft.magnets)
        board.select(copy.id)
    }

    private func reorder(forward: Bool) {
        guard let id = board.selectedID else { return }
        if forward { draft.bringForward(id) } else { draft.sendBackward(id) }
        board.render(draft.magnets)
        updateControls()
    }

    private func deleteSelected() {
        guard let id = board.selectedID else { return }
        draft.delete(id)
        board.render(draft.magnets)
        updateControls()
    }

    private func add(source: MagnetSource, builtInAssetID: String? = nil, localImageID: UUID? = nil, imageSize: CGSize) {
        let width = imageSize.width > imageSize.height * 1.2 ? 0.5 : MagnetGeometry.defaultWidth
        let style = MagnetStyle.defaultStyle(for: source)
        let imageAspect = imageSize.width > 0 ? Double(imageSize.height / imageSize.width) : 1
        let size = (width, width * style.outerAspect(imageAspect: imageAspect) * template.closedDoorAspect)
        guard let magnet = draft.add(source: source, builtInAssetID: builtInAssetID, localImageID: localImageID,
                                     size: size, style: style) else {
            showAlert(title: "磁鐵已滿", message: "每台冰箱最多 \(MagnetDraft.maxMagnets) 個磁鐵。")
            return
        }
        board.render(draft.magnets)
        board.select(magnet.id)
    }

    func save() {
        do {
            try library.commit(draft)
            // `onSaved` runs once the editor is gone, so the closed fridge is on screen again.
            dismiss(animated: true) { [onSaved] in onSaved?() }
        } catch {
            // The draft stays exactly as it is, so the user can retry.
            showAlert(title: "儲存失敗", message: "磁鐵的變更沒有儲存，請再試一次。")
        }
    }

    func cancel() {
        guard draft.hasChanges || !draft.importedImageIDs.isEmpty else {
            dismiss(animated: true)
            return
        }
        let alert = UIAlertController(title: "放棄這次的變更？", message: "冰箱上的磁鐵會回到編輯前的樣子。", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "繼續編輯", style: .cancel))
        alert.addAction(UIAlertAction(title: "放棄變更", style: .destructive) { [weak self] _ in
            guard let self else { return }
            self.library.discard(self.draft)
            self.dismiss(animated: true)
        })
        present(alert, animated: true)
    }

    private func showAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default))
        present(alert, animated: true)
    }

    // MARK: Built-in magnets

    private func showCatalog() {
        let catalog = MagnetCatalogViewController(catalog: library.catalog) { [weak self] item in
            guard let self, let image = self.library.catalog.image(id: item.id) else { return }
            self.add(source: .builtIn, builtInAssetID: item.id, imageSize: image.size)
        }
        let navigation = UINavigationController(rootViewController: catalog)
        navigation.sheetPresentationController?.detents = [.custom(identifier: .init("magnets.row")) { _ in 210 }]
        navigation.sheetPresentationController?.prefersGrabberVisible = true
        present(navigation, animated: true)
    }

    // MARK: Photos

    /// The system picker runs out of process: no photo-library permission is requested and only the chosen
    /// photo is handed to the app.
    private func showPhotoPicker() {
        var configuration = PHPickerConfiguration()
        configuration.filter = .images
        configuration.selectionLimit = 1
        configuration.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = self
        present(picker, animated: true)
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard let provider = results.first?.itemProvider else { return } // cancelled: nothing changes
        guard provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) else {
            showAlert(title: "無法加入照片", message: MagnetImageError.unsupported.message)
            return
        }
        spinner.startAnimating()
        view.isUserInteractionEnabled = false
        let images = library.images
        provider.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) { [weak self] url, _ in
            // The temporary file only exists inside this callback (background queue): downsample right here.
            let result: Result<ImportedMagnetImage, MagnetImageError>
            if let url {
                result = Result { try images.importImage(at: url) }.mapError { $0 as? MagnetImageError ?? .decodeFailed }
            } else {
                result = .failure(.decodeFailed)
            }
            DispatchQueue.main.async {
                guard let self else {
                    if case let .success(image) = result { images.remove(image.id) }
                    return
                }
                self.spinner.stopAnimating()
                self.view.isUserInteractionEnabled = true
                switch result {
                case let .success(image):
                    self.add(source: .photo, localImageID: image.id, imageSize: image.pixelSize)
                case let .failure(error):
                    self.showAlert(title: "無法加入照片", message: error.message)
                }
            }
        }
    }
}

/// Built-in magnets as one horizontally scrolling row of pictures (no labels).
final class MagnetCatalogViewController: UIViewController, UICollectionViewDataSource, UICollectionViewDelegate {
    private let catalog: MagnetCatalog
    private let onPick: (MagnetCatalogItem) -> Void
    private lazy var collectionView = UICollectionView(frame: .zero, collectionViewLayout: Self.makeLayout())

    init(catalog: MagnetCatalog, onPick: @escaping (MagnetCatalogItem) -> Void) {
        self.catalog = catalog
        self.onPick = onPick
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private static func makeLayout() -> UICollectionViewCompositionalLayout {
        let configuration = UICollectionViewCompositionalLayoutConfiguration()
        configuration.scrollDirection = .horizontal
        let item = NSCollectionLayoutItem(layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .fractionalHeight(1)))
        let group = NSCollectionLayoutGroup.horizontal(layoutSize: .init(widthDimension: .absolute(124), heightDimension: .absolute(124)),
                                                       subitems: [item])
        let section = NSCollectionLayoutSection(group: group)
        section.interGroupSpacing = 12
        section.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: Theme.Metric.gutter, bottom: 8, trailing: Theme.Metric.gutter)
        return UICollectionViewCompositionalLayout(section: section, configuration: configuration)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "內建磁鐵"
        view.backgroundColor = Theme.Color.background
        collectionView.backgroundColor = .clear
        collectionView.showsHorizontalScrollIndicator = false
        collectionView.alwaysBounceVertical = false
        collectionView.accessibilityIdentifier = "magnets.catalog"
        collectionView.register(MagnetCatalogCell.self, forCellWithReuseIdentifier: "item")
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 4),
            collectionView.heightAnchor.constraint(equalToConstant: 140),
        ])
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        })
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { catalog.items.count }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "item", for: indexPath)
        let item = catalog.items[indexPath.item]
        (cell as? MagnetCatalogCell)?.configure(image: catalog.thumbnail(id: item.id), id: item.id, index: indexPath.item)
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        let item = catalog.items[indexPath.item]
        dismiss(animated: true) { [onPick] in onPick(item) }
    }
}

/// Picture only, on a soft card.
final class MagnetCatalogCell: UICollectionViewCell {
    private let imageView = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = Theme.Color.interior
        contentView.layer.cornerRadius = 16
        contentView.layer.borderWidth = 1
        contentView.layer.borderColor = Theme.Color.divider.cgColor
        imageView.contentMode = .scaleAspectFit
        imageView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            imageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            imageView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            imageView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),
        ])
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(image: UIImage?, id: String, index: Int) {
        imageView.image = image
        accessibilityLabel = "內建磁鐵 \(index + 1)"
        accessibilityIdentifier = "magnets.catalog.\(id)"
    }

    override var isHighlighted: Bool {
        didSet { contentView.alpha = isHighlighted ? 0.7 : 1 }
    }
}
