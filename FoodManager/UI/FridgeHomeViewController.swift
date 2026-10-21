import UIKit
import os

/// Home screen: closed fridge + dashboard, or the open flat fridge.
/// Normal mode: tap a compartment → its food list. Edit mode: tap a compartment → layout editing.
final class FridgeHomeViewController: UIViewController {
    private let store: FridgeStore
    private let foodStore: FoodStore
    /// Food rules always validate against the *persisted* layout, never an unsaved edit.
    private lazy var inventory = FoodInventoryService(store: foodStore, fridgeID: fridge.id,
                                                      compartments: { [weak self] in self?.fridge.allCompartments ?? [] })
    private weak var foodListSheet: FoodListSheetController?
    private let template: FridgeTemplate
    private let logger = Logger(subsystem: "FoodManager.HowCode", category: "Home")

    /// Last persisted fridge. While editing, the UI renders `editor.working` instead.
    private var fridge: Fridge
    private var editor: FridgeLayoutEditor?
    private var selectedID: UUID?
    private weak var editSheet: CompartmentEditSheetController?
    private var loadError: Error?

    private var displayedFridge: Fridge { editor?.working ?? fridge }
    private var isEditingLayout: Bool { editor != nil }

    // Header
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private lazy var closeDoorButton = UIButton.sketchButton(title: "關門")
    private lazy var editButton = UIButton.sketchButton(title: "編輯", systemImage: "square.and.pencil")
    private lazy var cancelButton = UIButton.sketchButton(title: "取消")
    private lazy var saveButton = UIButton.sketchButton(title: "儲存", filled: true)

    // Global food actions (hidden while editing the layout)
    private let actionBar = UIStackView()
    private lazy var searchButton = UIButton.sketchButton(title: "搜尋", systemImage: "magnifyingglass")
    private lazy var addFoodButton = UIButton.sketchButton(title: "新增食材", systemImage: "plus", filled: true)

    // Closed state
    private let closedContainer = UIView()
    private let closedFridgeButton: ClosedFridgeButton
    private let dashboardView = DashboardView()

    // Open state
    private let openContainer = UIView()
    private let fridgeView: FridgeView
    private let editBar = UIStackView()
    private lazy var addButton = UIButton.sketchButton(title: "新增空間", systemImage: "plus")
    private let statusLabel = UILabel()
    /// Editing pins the fridge under the add bar (clear of the edit sheet); otherwise it is centred.
    private var fridgeTopWhenEditing: NSLayoutConstraint?
    private var fridgeCenteredWhenBrowsing: NSLayoutConstraint?

    init(store: FridgeStore, foodStore: FoodStore, template: FridgeTemplate = FridgeTemplateCatalog.defaultTemplate) {
        self.store = store
        self.foodStore = foodStore
        do {
            fridge = try store.loadOrCreateFridge()
        } catch {
            fridge = FridgeFactory.makeDefault(template: template)
            loadError = error
        }
        self.template = FridgeTemplateCatalog.template(id: fridge.templateID)
        closedFridgeButton = ClosedFridgeButton(template: self.template)
        fridgeView = FridgeView(template: self.template)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.Color.background
        buildActionBar() // before the header: the state containers are pinned above it
        buildHeader()
        buildClosedState()
        buildOpenState()
        wireActions()
        render(animated: false)
        applyDoorState(fridge.lastDoorState, animated: false)
        updateDashboard()
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(inventoryDidChange), name: .foodInventoryDidChange, object: nil)
        // Day-based counts (expiry, storage duration) change at midnight and while the app is in the background.
        center.addObserver(self, selector: #selector(inventoryDidChange), name: UIApplication.significantTimeChangeNotification, object: nil)
        center.addObserver(self, selector: #selector(inventoryDidChange), name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    @objc private func inventoryDidChange() {
        render(animated: false)
        updateDashboard()
    }

    private func updateDashboard() {
        dashboardView.provider = InventoryDashboardProvider(items: inventory.items, compartments: fridge.allCompartments,
                                                            aggregator: DashboardAggregator(), now: Date())
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if let loadError {
            self.loadError = nil
            logger.error("Failed to load fridge: \(String(describing: loadError))")
            showAlert(title: "無法讀取資料", message: "已暫時使用預設冰箱，變更可能無法儲存。")
        }
    }

    // MARK: - Layout

    private func buildHeader() {
        titleLabel.font = Theme.Font.title
        titleLabel.textColor = Theme.Color.textPrimary
        titleLabel.adjustsFontForContentSizeCategory = true
        subtitleLabel.font = Theme.Font.caption
        subtitleLabel.textColor = Theme.Color.textSecondary

        let titles = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
        titles.axis = .vertical
        titles.spacing = 2

        let buttons = UIStackView(arrangedSubviews: [closeDoorButton, editButton, cancelButton, saveButton])
        buttons.spacing = 8
        buttons.setContentCompressionResistancePriority(.required, for: .horizontal)

        let header = UIStackView(arrangedSubviews: [titles, UIView(), buttons])
        header.alignment = .center
        header.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(header)

        for container in [closedContainer, openContainer] {
            container.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(container)
            NSLayoutConstraint.activate([
                container.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
                container.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                container.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                container.bottomAnchor.constraint(equalTo: actionBar.topAnchor, constant: -8),
            ])
        }
        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: guide.topAnchor, constant: 8),
            header.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: Theme.Metric.gutter),
            header.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -Theme.Metric.gutter),
            header.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
    }

    private func buildActionBar() {
        actionBar.addArrangedSubview(searchButton)
        actionBar.addArrangedSubview(addFoodButton)
        actionBar.spacing = 12
        actionBar.distribution = .fillEqually
        actionBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(actionBar)
        NSLayoutConstraint.activate([
            actionBar.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: Theme.Metric.gutter),
            actionBar.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -Theme.Metric.gutter),
            actionBar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),
            actionBar.heightAnchor.constraint(equalToConstant: 44),
        ])
    }

    private func buildClosedState() {
        let hint = UILabel()
        hint.text = "輕點冰箱打開"
        hint.font = Theme.Font.caption
        hint.textColor = Theme.Color.textSecondary
        hint.textAlignment = .center

        for subview in [closedFridgeButton, dashboardView, hint] as [UIView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            closedContainer.addSubview(subview)
        }
        let c = closedContainer
        // Fridge takes ~55% of the width but never exceeds the available height.
        let preferredWidth = closedFridgeButton.widthAnchor.constraint(equalTo: c.widthAnchor, multiplier: 0.55)
        preferredWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            closedFridgeButton.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: Theme.Metric.gutter),
            closedFridgeButton.centerYAnchor.constraint(equalTo: c.centerYAnchor, constant: -24),
            closedFridgeButton.widthAnchor.constraint(equalTo: closedFridgeButton.heightAnchor,
                                                      multiplier: closedFridgeButton.artworkAspectRatio),
            closedFridgeButton.heightAnchor.constraint(lessThanOrEqualTo: c.heightAnchor, constant: -80),
            preferredWidth,

            hint.topAnchor.constraint(equalTo: closedFridgeButton.bottomAnchor, constant: 12),
            hint.centerXAnchor.constraint(equalTo: closedFridgeButton.centerXAnchor),

            dashboardView.leadingAnchor.constraint(equalTo: closedFridgeButton.trailingAnchor, constant: 24),
            dashboardView.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -Theme.Metric.gutter),
            // Room for the 全部/冷藏/冷凍 switch; the fridge's preferred width yields first.
            dashboardView.widthAnchor.constraint(greaterThanOrEqualToConstant: 132),
            dashboardView.centerYAnchor.constraint(equalTo: closedFridgeButton.centerYAnchor),
        ])
    }

    private func buildOpenState() {
        // One compact "新增空間" menu replaces the old row of add buttons.
        var config = addButton.configuration
        config?.indicator = .popup
        addButton.configuration = config
        addButton.menu = UIMenu(title: "新增空間", children: AddCompartmentOption.allCases.map { option in
            UIAction(title: option.title, image: Self.menuImage(for: option.storageType)) { [weak self] _ in
                self?.addCompartment(option)
            }
        })
        addButton.showsMenuAsPrimaryAction = true
        addButton.preferredMenuElementOrder = .fixed
        addButton.setContentHuggingPriority(.required, for: .horizontal)

        statusLabel.font = Theme.Font.caption
        statusLabel.textColor = Theme.Color.destructive
        statusLabel.numberOfLines = 2
        statusLabel.adjustsFontSizeToFitWidth = true

        editBar.addArrangedSubview(addButton)
        editBar.addArrangedSubview(statusLabel)
        editBar.spacing = 12
        editBar.alignment = .center

        for subview in [editBar, fridgeView] as [UIView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            openContainer.addSubview(subview)
        }
        let c = openContainer
        let inset = Theme.Metric.openFridgeInset
        // Width-limited in portrait: fill the width (keeping the artwork's aspect ratio) unless height runs out.
        let preferredWidth = fridgeView.widthAnchor.constraint(equalTo: c.widthAnchor, constant: -2 * inset)
        preferredWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            editBar.topAnchor.constraint(equalTo: c.topAnchor),
            editBar.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: Theme.Metric.gutter),
            editBar.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -Theme.Metric.gutter),

            fridgeView.topAnchor.constraint(greaterThanOrEqualTo: c.topAnchor, constant: 8),
            fridgeView.centerXAnchor.constraint(equalTo: c.centerXAnchor),
            fridgeView.widthAnchor.constraint(equalTo: fridgeView.heightAnchor, multiplier: fridgeView.artworkAspectRatio),
            fridgeView.widthAnchor.constraint(lessThanOrEqualTo: c.widthAnchor, constant: -2 * inset),
            fridgeView.bottomAnchor.constraint(lessThanOrEqualTo: c.bottomAnchor, constant: -8),
            preferredWidth,
        ])
        // Editing pins the fridge just under the edit bar so the compact sheet covers as little as possible.
        fridgeTopWhenEditing = fridgeView.topAnchor.constraint(equalTo: editBar.bottomAnchor, constant: 12)
        fridgeCenteredWhenBrowsing = fridgeView.centerYAnchor.constraint(equalTo: c.centerYAnchor, constant: -16)
    }

    private static func menuImage(for storage: StorageType) -> UIImage? {
        guard let color = Theme.Color.indicator(for: storage) else { return UIImage(systemName: "rectangle.split.1x2") }
        return UIImage(systemName: "circle.fill")?.withTintColor(color, renderingMode: .alwaysOriginal)
    }

    private func wireActions() {
        closedFridgeButton.addAction(UIAction { [weak self] _ in self?.setDoor(.open) }, for: .touchUpInside)
        closeDoorButton.addAction(UIAction { [weak self] _ in self?.setDoor(.closed) }, for: .touchUpInside)
        editButton.addAction(UIAction { [weak self] _ in self?.beginEditing() }, for: .touchUpInside)
        cancelButton.addAction(UIAction { [weak self] _ in self?.cancelTapped() }, for: .touchUpInside)
        saveButton.addAction(UIAction { [weak self] _ in self?.saveTapped() }, for: .touchUpInside)
        fridgeView.onSelectCompartment = { [weak self] id in self?.compartmentTapped(id) }
        fridgeView.summaryProvider = { [weak self] id in self?.inventory.contentSummary(for: id) ?? .empty }
        searchButton.addAction(UIAction { [weak self] _ in self?.openSearch() }, for: .touchUpInside)
        addFoodButton.addAction(UIAction { [weak self] _ in self?.openFoodEditor(.add(compartmentID: nil)) }, for: .touchUpInside)
        closeDoorButton.accessibilityLabel = "關上冰箱"
    }

    // MARK: - Rendering

    private func render(animated: Bool) {
        let isOpen = fridge.lastDoorState == .open
        titleLabel.text = isEditingLayout ? "編輯隔層" : "冰箱管理員"
        subtitleLabel.text = isEditingLayout ? "輕點隔層調整，完成後儲存" : (isOpen ? displayedFridge.name : "今天也好好保存食材")
        closeDoorButton.isHidden = !isOpen || isEditingLayout
        editButton.isHidden = !isOpen || isEditingLayout
        cancelButton.isHidden = !isEditingLayout
        saveButton.isHidden = !isEditingLayout
        editBar.isHidden = !isEditingLayout
        actionBar.isHidden = isEditingLayout
        fridgeCenteredWhenBrowsing?.isActive = !isEditingLayout
        fridgeTopWhenEditing?.isActive = isEditingLayout
        if animated && !UIAccessibility.isReduceMotionEnabled {
            UIView.animate(withDuration: 0.3) { self.openContainer.layoutIfNeeded() }
        }
        fridgeView.update(fridge: displayedFridge, editing: isEditingLayout, selectedID: selectedID,
                          animated: animated && !UIAccessibility.isReduceMotionEnabled)
    }

    private func showStatus(_ message: String?) {
        statusLabel.text = message ?? " "
        if message != nil { UIAccessibility.post(notification: .announcement, argument: message) }
    }

    // MARK: - Door

    private func setDoor(_ state: DoorState) {
        guard !isEditingLayout, state != fridge.lastDoorState else { return }
        foodListSheet?.dismiss(animated: true)
        fridge.lastDoorState = state
        do {
            try store.saveDoorState(state, fridgeID: fridge.id)
        } catch {
            logger.error("Failed to persist door state: \(String(describing: error))")
        }
        applyDoorState(state, animated: true)
    }

    /// Layered cross-fade between the two artworks (0.4s). Reduce Motion drops the scale and shortens the fade.
    private func applyDoorState(_ state: DoorState, animated: Bool) {
        let isOpen = state == .open
        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        let shown = isOpen ? openContainer : closedContainer
        let hidden = isOpen ? closedContainer : openContainer
        render(animated: false)

        shown.isHidden = false
        guard animated else {
            shown.alpha = 1
            shown.transform = .identity
            hidden.alpha = 0
            hidden.isHidden = true
            return
        }
        if !reduceMotion {
            shown.transform = CGAffineTransform(scaleX: isOpen ? 0.96 : 1.03, y: isOpen ? 0.96 : 1.03)
        }
        view.isUserInteractionEnabled = false
        UIView.animate(withDuration: reduceMotion ? 0.2 : Theme.Animation.doorDuration, delay: 0,
                       options: [.curveEaseInOut]) {
            shown.alpha = 1
            shown.transform = .identity
            hidden.alpha = 0
            if !reduceMotion {
                hidden.transform = CGAffineTransform(scaleX: isOpen ? 1.03 : 0.96, y: isOpen ? 1.03 : 0.96)
            }
        } completion: { _ in
            hidden.isHidden = true
            hidden.transform = .identity
            self.view.isUserInteractionEnabled = true
            UIAccessibility.post(notification: .screenChanged, argument: shown)
        }
    }

    // MARK: - Editing

    private func beginEditing() {
        foodListSheet?.dismiss(animated: true)
        // Occupancy comes from real food records, so compartments holding food can't be deleted.
        editor = FridgeLayoutEditor(fridge: fridge, occupancy: inventory)
        selectedID = nil
        showStatus(nil)
        render(animated: true)
    }

    private func endEditing() {
        editSheet?.dismiss(animated: true)
        editor = nil
        selectedID = nil
        render(animated: true)
    }

    private func cancelTapped() {
        guard let editor, editor.hasChanges else { return endEditing() }
        let alert = UIAlertController(title: "放棄變更？", message: "這次的隔層調整將不會儲存。", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "繼續編輯", style: .cancel))
        alert.addAction(UIAlertAction(title: "放棄", style: .destructive) { [weak self] _ in self?.endEditing() })
        (presentedViewController ?? self).present(alert, animated: true)
    }

    private func saveTapped() {
        guard let editor else { return }
        do {
            let updated = try editor.commit()
            // Defense in depth: never persist a layout that would orphan active food.
            let keptIDs = Set(updated.allCompartments.map(\.id))
            if let orphaned = fridge.allCompartments.first(where: { !keptIDs.contains($0.id) && inventory.itemCount(in: $0.id) > 0 }) {
                throw LayoutEditError.compartmentOccupied(itemCount: inventory.itemCount(in: orphaned.id))
            }
            try store.saveLayout(updated)
            fridge = updated
            endEditing()
            updateDashboard() // storage types may have changed; food records are never rewritten
        } catch let error as LayoutEditError {
            showStatus(error.message)
        } catch {
            logger.error("Save failed: \(String(describing: error))")
            showAlert(title: "儲存失敗", message: "請再試一次。")
        }
    }

    private func addCompartment(_ option: AddCompartmentOption) {
        guard let editor else { return }
        do {
            let added = try editor.addCompartment(option)
            showStatus(nil)
            select(added.id)
        } catch let error as LayoutEditError {
            showStatus(error.message)
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        } catch {
            showStatus(error.localizedDescription)
        }
    }

    // MARK: - Food

    private func compartmentTapped(_ id: UUID) {
        if isEditingLayout { return select(id) }
        if let foodListSheet {
            foodListSheet.show(compartmentID: id)
            return
        }
        let sheet = FoodListSheetController(compartmentID: id, inventory: inventory,
                                            compartments: { [weak self] in self?.fridge.allCompartments ?? [] })
        sheet.onAddFood = { [weak self, weak sheet] id in self?.openFoodEditor(.add(compartmentID: id), from: sheet) }
        sheet.onEditFood = { [weak self, weak sheet] id in self?.openFoodEditor(.edit(foodID: id), from: sheet) }
        foodListSheet = sheet
        present(sheet, animated: true)
    }

    private func openFoodEditor(_ mode: FoodEditorViewController.Mode, from presenter: UIViewController? = nil) {
        guard !isEditingLayout else { return }
        if case .add(nil) = mode, fridge.allCompartments.isEmpty {
            return showAlert(title: "還沒有隔層", message: "請先在「編輯」中新增隔層。")
        }
        FoodEditorViewController.present(mode, inventory: inventory, compartments: fridge.allCompartments,
                                         from: presenter ?? presentedViewController ?? self)
    }

    private func openSearch() {
        FoodSearchViewController.present(inventory: inventory, compartments: { [weak self] in self?.fridge.allCompartments ?? [] },
                                         from: presentedViewController ?? self)
    }

    private func select(_ id: UUID) {
        guard let editor, let compartment = editor.compartment(id: id) else { return }
        selectedID = id
        showStatus(nil)
        render(animated: true)
        if let editSheet {
            editSheet.show(compartment)
        } else {
            let sheet = CompartmentEditSheetController(compartment: compartment)
            sheet.delegate = self
            editSheet = sheet
            present(sheet, animated: true)
        }
    }

    /// Runs one editor mutation, re-renders, and returns a user-facing error message on failure.
    private func performEdit(_ id: UUID, _ change: (FridgeLayoutEditor) throws -> Void) -> String? {
        guard let editor else { return nil }
        do {
            try change(editor)
        } catch let error as LayoutEditError {
            return error.message
        } catch {
            return error.localizedDescription
        }
        render(animated: true)
        if let updated = editor.compartment(id: id) { editSheet?.show(updated) }
        return nil
    }

    private func showAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default))
        (presentedViewController ?? self).present(alert, animated: true)
    }
}

extension FridgeHomeViewController: CompartmentEditSheetDelegate {
    func sheet(_ sheet: CompartmentEditSheetController, rename id: UUID, to name: String) -> String? {
        performEdit(id) { try $0.rename(id, to: name) }
    }

    func sheet(_ sheet: CompartmentEditSheetController, setStorage id: UUID, to storage: StorageType) -> String? {
        performEdit(id) { try $0.setStorageType(id, to: storage) }
    }

    func sheet(_ sheet: CompartmentEditSheetController, move id: UUID, _ direction: MoveDirection) -> String? {
        performEdit(id) { try $0.move(id, direction) }
    }

    func sheet(_ sheet: CompartmentEditSheetController, resize id: UUID, by delta: Double) -> String? {
        performEdit(id) { try $0.resize(id, by: delta) }
    }

    func sheet(_ sheet: CompartmentEditSheetController, delete id: UUID) -> String? {
        let error = performEdit(id) { try $0.delete(id) }
        if error == nil {
            selectedID = nil
            sheet.dismiss(animated: true)
            render(animated: true)
        }
        return error
    }

    func sheetDidDismiss(_ sheet: CompartmentEditSheetController) {
        selectedID = nil
        render(animated: true)
    }
}
