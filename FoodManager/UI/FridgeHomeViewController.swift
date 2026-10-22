import UIKit
import os

/// Home screen: closed fridge + dashboard, or the open flat fridge.
/// Normal mode: tap a compartment → its food list. Edit mode: tap a compartment → layout editing.
final class FridgeHomeViewController: UIViewController {
    private let store: FridgeStore
    private let foodStore: FoodStore
    /// All fridges + selection. The home screen shows one fridge; switching rebuilds it (see `onSwitchFridge`).
    let directory: FridgeDirectory
    /// Rebuilds the app for another fridge, then delivers `route` there (set by the scene delegate).
    var onSwitchFridge: ((UUID, ExternalRoute?) -> Void)?
    /// Rebuilds the app from storage after a restore touched the database (set by the scene delegate).
    /// The argument is nil on success, else the failure message to show.
    var onDataRestored: ((String?) -> Void)?
    private let makeBackupService: () -> BackupService
    private let magnetLibrary: MagnetLibrary
    /// Magnets on the closed door: display only, so taps still open the fridge.
    private lazy var magnetBoard = MagnetBoardView(template: template, library: magnetLibrary)
    private lazy var decorateButton: UIButton = {
        let button = UIButton.sketchButton(title: "裝飾冰箱", systemImage: "sparkles")
        button.accessibilityIdentifier = "home.decorate"
        return button
    }()
    /// Food rules always validate against the *persisted* layout, never an unsaved edit.
    private lazy var inventory = FoodInventoryService(store: foodStore, fridgeID: fridge.id,
                                                      compartments: { [weak self] in self?.fridge.allCompartments ?? [] })
    private weak var foodListSheet: FoodListSheetController?
    private let notificationClient: NotificationClient
    private let widgetPublisher: WidgetSnapshotPublisher
    /// Keeps pending notifications in sync with the persisted inventory (a delivery mechanism only).
    private lazy var notifications = NotificationCoordinator(
        client: notificationClient, preferencesStore: UserDefaultsNotificationPreferencesStore(),
        snapshot: { [weak self] in self?.allFridgesData().map { ($0.items, $0.compartments) } })
    private let template: FridgeTemplate
    private let logger = Logger(subsystem: "FoodManager.HowCode", category: "Home")

    /// Last persisted fridge. While editing, the UI renders `editor.working` instead.
    private var fridge: Fridge
    private var editor: FridgeLayoutEditor?
    private var selectedID: UUID?
    private weak var editSheet: CompartmentEditSheetController?
    /// Non-none while a damaged stored layout is shown in repaired form and the user hasn't confirmed
    /// overwriting the original bytes yet.
    private var layoutRecovery: LayoutRecovery
    private var hasPresentedRecoveryNotice = false

    private var displayedFridge: Fridge { editor?.working ?? fridge }
    private var isEditingLayout: Bool { editor != nil }

    // Header
    private let titleLabel = UILabel()
    private let fridgeCaption = UILabel()
    /// Fridge name + chevron; opens the fridge menu (switch / add / manage).
    private let fridgeSelector = UIButton(type: .system)
    private let subtitleLabel = UILabel()
    private lazy var closeDoorButton = UIButton.sketchButton(title: "關門")
    private lazy var editButton = UIButton.sketchButton(title: "編輯", systemImage: "square.and.pencil")
    private lazy var cancelButton = UIButton.sketchButton(title: "取消")
    private lazy var saveButton = UIButton.sketchButton(title: "儲存", filled: true)
    private lazy var settingsButton: UIButton = {
        let button = UIButton.sketchButton(title: "", systemImage: "gearshape")
        button.accessibilityLabel = "設定"
        button.accessibilityIdentifier = "home.settings"
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: Theme.Metric.minTouchTarget).isActive = true
        return button
    }()

    // Monetization (nil in tests / UI tests: no StoreKit, no ads).
    private let entitlements: EntitlementService?
    private let ads: AdsCoordinator?
    /// Closed-home banner; only placement in the app.
    private lazy var bannerContainer: BannerAdContainerView? = ads.map { ads in
        BannerAdContainerView(makeLoader: makeBannerLoader ?? { GoogleBannerLoader(unitID: ads.configuration.bannerUnitID) })
    }
    private let makeBannerLoader: (() -> BannerAdLoading)?

    private lazy var reminderButton: UIButton = {
        let button = UIButton.sketchButton(title: "", systemImage: "bell")
        button.accessibilityLabel = "食材提醒"
        button.accessibilityIdentifier = "home.reminders"
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: Theme.Metric.minTouchTarget).isActive = true
        return button
    }()

    // Global food actions (hidden while editing the layout)
    private let actionBar = UIStackView()
    private let footer = UIStackView()
    private let statusBanner = UIButton(type: .system)
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

    /// Only constructed once storage is confirmed available and the fridge loaded (see `AppBootstrap`).
    /// Only persistent storage publishes widget snapshots; temporary in-memory sessions (tests, UI tests)
    /// never overwrite what the user's widgets show.
    init(session: AppSession, notificationClient: NotificationClient = SystemNotificationClient(),
         widgetPublisher: WidgetSnapshotPublisher? = nil, entitlements: EntitlementService? = nil,
         ads: AdsCoordinator? = nil, makeBannerLoader: (() -> BannerAdLoading)? = nil) {
        self.notificationClient = notificationClient
        self.entitlements = entitlements
        self.ads = ads
        self.makeBannerLoader = makeBannerLoader
        self.widgetPublisher = widgetPublisher
            ?? (session.mode == .persistent ? WidgetSnapshotPublisher() : WidgetSnapshotPublisher(file: nil))
        store = session.fridgeStore
        directory = session.directory
        foodStore = session.foodStore
        makeBackupService = { session.makeBackupService() }
        magnetLibrary = session.magnets
        fridge = session.loadResult.fridge
        layoutRecovery = session.loadResult.recovery
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
        center.addObserver(self, selector: #selector(reminderConfigured), name: .foodReminderConfigured, object: nil)
        notifications.scheduleUpdate()
        publishWidgetSnapshot()
        reloadMagnets()
    }

    // MARK: - Magnets

    /// Shows this fridge's saved magnets on the closed door. A read failure leaves the door plain (never wrong).
    private func reloadMagnets() {
        magnetBoard.render((try? magnetLibrary.magnets(fridgeID: fridge.id)) ?? [])
    }

    /// Nothing is being edited or shown on top: safe to rebuild the screen with data that arrived from iCloud.
    var canBeRebuilt: Bool {
        isViewLoaded && !isEditingLayout && presentedViewController == nil && navigationController?.topViewController === self
    }

    func openMagnetEditor() {
        guard !isEditingLayout, presentedViewController == nil else { return }
        let magnets: [FridgeMagnet]
        do {
            magnets = try magnetLibrary.magnets(fridgeID: fridge.id)
        } catch {
            showAlert(title: "無法讀取磁鐵", message: "請再試一次。")
            return
        }
        let editor = MagnetEditorViewController(fridge: fridge, library: magnetLibrary, magnets: magnets)
        editor.onSaved = { [weak self] in
            self?.reloadMagnets()
            self?.showRouteMessage("已儲存冰箱裝飾")
        }
        present(editor, animated: true)
    }

    /// Contextual permission prompt: offered once, right after the user sets an expiry or storage reminder.
    @objc private func reminderConfigured() {
        Task { @MainActor in
            var preferences = notifications.preferences
            guard !preferences.hasShownPermissionPrompt, await notifications.authorizationStatus() == .notDetermined else { return }
            preferences.hasShownPermissionPrompt = true
            notifications.preferencesStore.save(preferences)
            try? await Task.sleep(nanoseconds: 600_000_000) // let the editor finish dismissing
            let alert = UIAlertController(title: "要開啟食材通知嗎？",
                                          message: "在食材快到期，或存放到你設定的天數時提醒你。不開啟也能在「食材提醒」查看，之後可在通知設定更改。",
                                          preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "暫時不要", style: .cancel))
            alert.addAction(UIAlertAction(title: "開啟通知", style: .default) { [weak self] _ in
                Task { @MainActor in _ = await self?.notifications.requestAuthorization() }
            })
            topPresenter.present(alert, animated: true)
        }
    }

    private var topPresenter: UIViewController {
        var top: UIViewController = navigationController ?? self
        while let presented = top.presentedViewController { top = presented }
        return top
    }

    /// Publishes the widget snapshot only from successfully loaded data (never after a failed read;
    /// food changes only notify after they were persisted). Runs off the main thread.
    private func publishWidgetSnapshot(completion: ((Bool) -> Void)? = nil) {
        guard inventory.loadState == .loaded, let data = allFridgesData() else {
            completion?(false)
            return
        }
        widgetPublisher.publish(fridges: data.fridges, items: data.items, selectedFridgeID: fridge.id, completion: completion)
    }

    /// After a restore: reschedules notifications and regenerates widget snapshots from the restored data.
    /// Reports what couldn't be refreshed (the restored data itself is already saved).
    func syncAfterRestore() async -> [String] {
        var problems: [String] = []
        if await !notifications.syncNow() { problems.append("通知") }
        let widgetsUpdated = await withCheckedContinuation { continuation in
            publishWidgetSnapshot { continuation.resume(returning: $0) }
        }
        if !widgetsUpdated { problems.append("小工具") }
        return problems
    }

    /// Every fridge with its active food: this fridge from memory (freshest), the others from storage.
    /// nil if another fridge's food can't be read (callers then skip work instead of acting on partial data).
    func allFridgesData() -> (fridges: [Fridge], items: [FoodItem], compartments: [Compartment])? {
        let fridges = directory.fridges.map { $0.id == fridge.id ? fridge : $0 }
        guard fridges.contains(where: { $0.id == fridge.id }) else { return nil }
        var items = inventory.items
        for other in fridges where other.id != fridge.id {
            guard let food = try? foodStore.activeItems(fridgeID: other.id) else { return nil }
            items += food
        }
        return (fridges, items, fridges.flatMap(\.allCompartments))
    }

    @objc private func fridgesChanged() {
        if let renamed = directory.fridge(id: fridge.id) { fridge.name = renamed.name }
        render(animated: false)
        publishWidgetSnapshot()
        notifications.scheduleUpdate()
    }

    @objc private func inventoryDidChange() {
        publishWidgetSnapshot()
        render(animated: false)
        updateDashboard()
        updateStatusBanner()
        notifications.scheduleUpdate()
    }

    private func updateDashboard() {
        // A failed read must not look like an empty fridge: show dashes until data loads.
        dashboardView.provider = inventory.loadState.isFailed && inventory.items.isEmpty
            ? PlaceholderDashboardProvider()
            : InventoryDashboardProvider(items: inventory.items, compartments: fridge.allCompartments,
                                         aggregator: DashboardAggregator(), now: Date())
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Home draws its own header; pushed screens (reminder center) use the navigation bar.
        navigationController?.setNavigationBarHidden(true, animated: animated)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        AppNotificationRouter.shared.attach(self)
        prepareAdsIfNeeded()
        if layoutRecovery.needsConfirmation && !hasPresentedRecoveryNotice {
            hasPresentedRecoveryNotice = true
            presentRecoveryNotice()
        }
    }

    // MARK: - Status banner (load failure, unplaced food, pending layout repair)

    private enum BannerState: Equatable {
        case hidden
        case loadFailed
        case unplacedFood(Int)
        case layoutNeedsConfirmation
    }

    private var bannerState: BannerState {
        if inventory.loadState.isFailed { return .loadFailed }
        let unplaced = inventory.itemsWithMissingCompartment.count
        if unplaced > 0 { return .unplacedFood(unplaced) }
        if layoutRecovery.needsConfirmation { return .layoutNeedsConfirmation }
        return .hidden
    }

    private func updateStatusBanner() {
        let state = isEditingLayout ? .hidden : bannerState
        statusBanner.isHidden = state == .hidden
        let title: String
        switch state {
        case .hidden: title = ""
        case .loadFailed: title = "無法讀取食材資料，輕點重試"
        case let .unplacedFood(count): title = "有 \(count) 項食材需要重新放置"
        case .layoutNeedsConfirmation: title = "隔層資料已暫時修復，輕點確認"
        }
        var config = statusBanner.configuration
        config?.title = title
        statusBanner.configuration = config
        statusBanner.accessibilityLabel = title
    }

    private func statusBannerTapped() {
        switch bannerState {
        case .hidden: break
        case .loadFailed: inventory.retryLoading()
        case .unplacedFood: openSearch(mode: .unplaced)
        case .layoutNeedsConfirmation: presentRecoveryNotice()
        }
    }

    /// Explains a damaged layout and lets the user decide whether to overwrite the original stored bytes.
    private func presentRecoveryNotice(then onConfirmed: (() -> Void)? = nil) {
        let unplaced = inventory.itemsWithMissingCompartment.count
        var message: String
        switch layoutRecovery {
        case .none: return
        case .repaired:
            message = "儲存的隔層資料有錯誤，已暫時調整隔層大小，所有隔層與食材都保留。"
        case .replacedWithDefault:
            message = "儲存的隔層資料無法讀取，目前暫時顯示預設隔層。"
        }
        if unplaced > 0 { message += "\n有 \(unplaced) 項食材的原本位置已不存在，請重新放置（不會自動移動）。" }
        message += "\n原始資料仍保留；確認後才會以目前的隔層覆寫。"
        let alert = UIAlertController(title: "冰箱隔層資料需要修復", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "稍後再說", style: .cancel))
        alert.addAction(UIAlertAction(title: "儲存目前隔層", style: .default) { [weak self] _ in
            guard let self else { return }
            do {
                try self.store.saveLayout(self.fridge)
                self.layoutRecovery = .none
                self.publishWidgetSnapshot()
                self.updateStatusBanner()
                onConfirmed?()
            } catch {
                self.logger.error("Saving recovered layout failed: \(String(describing: error), privacy: .private)")
                self.showAlert(title: "儲存失敗", message: "隔層資料沒有變更，請再試一次。")
            }
        })
        (presentedViewController ?? self).present(alert, animated: true)
    }

    // MARK: - Layout

    private func buildHeader() {
        titleLabel.font = Theme.Font.title
        titleLabel.textColor = Theme.Color.textPrimary
        titleLabel.adjustsFontForContentSizeCategory = true
        subtitleLabel.font = Theme.Font.caption
        subtitleLabel.textColor = Theme.Color.textSecondary

        fridgeCaption.text = "目前使用的冰箱"
        fridgeCaption.font = Theme.Font.caption
        fridgeCaption.textColor = Theme.Color.textSecondary
        configureFridgeSelector()
        let titles = UIStackView(arrangedSubviews: [fridgeCaption, fridgeSelector, titleLabel, subtitleLabel])
        titles.axis = .vertical
        titles.spacing = 2

        let buttons = UIStackView(arrangedSubviews: [settingsButton, reminderButton, editButton, cancelButton, saveButton])
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
                container.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -8),
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
        actionBar.heightAnchor.constraint(equalToConstant: 44).isActive = true
        searchButton.accessibilityIdentifier = "home.search"
        addFoodButton.accessibilityIdentifier = "home.addFood"

        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: "exclamationmark.circle")
        config.imagePadding = 6
        config.baseForegroundColor = Theme.Color.textPrimary
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attrs in
            var attrs = attrs
            attrs.font = UIFont.preferredFont(forTextStyle: .footnote)
            return attrs
        }
        statusBanner.configuration = config
        statusBanner.backgroundColor = Theme.Color.fridgeBody
        statusBanner.layer.cornerRadius = 10
        statusBanner.isHidden = true
        statusBanner.accessibilityIdentifier = "home.statusBanner"
        statusBanner.heightAnchor.constraint(greaterThanOrEqualToConstant: 40).isActive = true
        statusBanner.addAction(UIAction { [weak self] _ in self?.statusBannerTapped() }, for: .touchUpInside)

        footer.axis = .vertical
        footer.spacing = 8
        footer.addArrangedSubview(statusBanner)
        if let bannerContainer { footer.addArrangedSubview(bannerContainer) }
        footer.addArrangedSubview(actionBar)
        footer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(footer)
        NSLayoutConstraint.activate([
            footer.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: Theme.Metric.gutter),
            footer.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -Theme.Metric.gutter),
            footer.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),
        ])
    }

    private func buildClosedState() {
        let hint = UILabel()
        hint.text = "輕點冰箱打開"
        hint.font = Theme.Font.caption
        hint.textColor = Theme.Color.textSecondary
        hint.textAlignment = .center

        for subview in [closedFridgeButton, magnetBoard, dashboardView, hint, decorateButton] as [UIView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            closedContainer.addSubview(subview)
        }
        let c = closedContainer
        // On short screens the dashboard moves up to make room for 裝飾冰箱 below it.
        let dashboardCentered = dashboardView.centerYAnchor.constraint(equalTo: closedFridgeButton.centerYAnchor)
        dashboardCentered.priority = .defaultHigh
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
            dashboardCentered,

            // Exactly over the artwork, so the board can find the door surface inside it.
            magnetBoard.topAnchor.constraint(equalTo: closedFridgeButton.topAnchor),
            magnetBoard.leadingAnchor.constraint(equalTo: closedFridgeButton.leadingAnchor),
            magnetBoard.trailingAnchor.constraint(equalTo: closedFridgeButton.trailingAnchor),
            magnetBoard.bottomAnchor.constraint(equalTo: closedFridgeButton.bottomAnchor),

            decorateButton.leadingAnchor.constraint(equalTo: dashboardView.leadingAnchor),
            decorateButton.trailingAnchor.constraint(lessThanOrEqualTo: dashboardView.trailingAnchor),
            decorateButton.bottomAnchor.constraint(equalTo: closedFridgeButton.bottomAnchor),
            dashboardView.bottomAnchor.constraint(lessThanOrEqualTo: decorateButton.topAnchor, constant: -12),
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

        for subview in [editBar, fridgeView, closeDoorButton] as [UIView] {
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

            // 關門 sits right under the fridge, where the door is (hidden while editing the layout).
            closeDoorButton.topAnchor.constraint(equalTo: fridgeView.bottomAnchor, constant: 20),
            closeDoorButton.centerXAnchor.constraint(equalTo: c.centerXAnchor),
            closeDoorButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
            closeDoorButton.heightAnchor.constraint(greaterThanOrEqualToConstant: Theme.Metric.minTouchTarget),
            closeDoorButton.bottomAnchor.constraint(lessThanOrEqualTo: c.bottomAnchor, constant: -8),
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
        decorateButton.addAction(UIAction { [weak self] _ in self?.openMagnetEditor() }, for: .touchUpInside)
        closeDoorButton.addAction(UIAction { [weak self] _ in self?.setDoor(.closed) }, for: .touchUpInside)
        editButton.addAction(UIAction { [weak self] _ in self?.beginEditing() }, for: .touchUpInside)
        cancelButton.addAction(UIAction { [weak self] _ in self?.cancelTapped() }, for: .touchUpInside)
        saveButton.addAction(UIAction { [weak self] _ in self?.saveTapped() }, for: .touchUpInside)
        fridgeView.onSelectCompartment = { [weak self] id in self?.compartmentTapped(id) }
        fridgeView.summaryProvider = { [weak self] id in self?.inventory.contentSummary(for: id) ?? .empty }
        searchButton.addAction(UIAction { [weak self] _ in self?.openSearch() }, for: .touchUpInside)
        reminderButton.addAction(UIAction { [weak self] _ in self?.openReminderCenter() }, for: .touchUpInside)
        settingsButton.addAction(UIAction { [weak self] _ in self?.openSettings() }, for: .touchUpInside)
        for name in [Notification.Name.entitlementsDidChange, .adAvailabilityDidChange] {
            NotificationCenter.default.addObserver(self, selector: #selector(monetizationChanged), name: name, object: nil)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(fridgesChanged), name: .fridgesDidChange, object: nil)
        dashboardView.onSelectReminder = { [weak self] kind, storage in self?.openReminderCenter(kind: kind, storage: storage) }
        addFoodButton.addAction(UIAction { [weak self] _ in self?.openFoodEditor(.add(compartmentID: nil)) }, for: .touchUpInside)
        closeDoorButton.accessibilityLabel = "關上冰箱"
    }

    // MARK: - Rendering

    private func render(animated: Bool) {
        let isOpen = fridge.lastDoorState == .open
        titleLabel.text = "編輯隔層"
        subtitleLabel.text = "輕點隔層調整，完成後儲存"
        titleLabel.isHidden = !isEditingLayout
        subtitleLabel.isHidden = !isEditingLayout
        fridgeCaption.isHidden = isEditingLayout
        fridgeSelector.isHidden = isEditingLayout
        var selectorConfig = fridgeSelector.configuration
        selectorConfig?.title = fridge.name
        fridgeSelector.configuration = selectorConfig
        fridgeSelector.accessibilityLabel = "目前冰箱：" + fridge.name
        closeDoorButton.isHidden = !isOpen || isEditingLayout
        editButton.isHidden = !isOpen || isEditingLayout
        cancelButton.isHidden = !isEditingLayout
        saveButton.isHidden = !isEditingLayout
        editBar.isHidden = !isEditingLayout
        reminderButton.isHidden = isEditingLayout
        settingsButton.isHidden = isEditingLayout
        updateBanner()
        actionBar.isHidden = isEditingLayout
        updateStatusBanner()
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
        guard layoutRecovery.needsConfirmation else { return commitLayoutEdits() }
        // The stored layout was damaged: saving overwrites the original bytes, so ask first.
        let alert = UIAlertController(title: "覆寫原本的隔層資料？",
                                      message: "原本儲存的隔層資料已損壞。儲存後會以目前編輯的隔層取代它。",
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "覆寫並儲存", style: .destructive) { [weak self] _ in self?.commitLayoutEdits() })
        (presentedViewController ?? self).present(alert, animated: true)
    }

    private func commitLayoutEdits() {
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
            layoutRecovery = .none
            endEditing()
            notifications.scheduleUpdate() // compartment names appear in notification text
            updateDashboard() // storage types may have changed; food records are never rewritten
            publishWidgetSnapshot()
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
        sheet.otherFridges = { [weak self] in
            guard let self else { return [] }
            return self.directory.fridges.filter { $0.id != self.fridge.id }
        }
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

    /// Pushes the reminder center (door state is untouched; Back returns to the same fridge view).
    func openReminderCenter(kind: ReminderKindFilter = .all, storage: StorageFilter = .all) {
        guard !isEditingLayout else { return }
        if presentedViewController != nil { dismiss(animated: false) }
        let center = ReminderCenterViewController(inventory: inventory,
                                                  compartments: { [weak self] in self?.fridge.allCompartments ?? [] },
                                                  storageFilter: storage, kindFilter: kind)
        center.allFridges = { [weak self] in
            guard let self, let data = self.allFridgesData() else { return nil }
            return .init(items: data.items, compartments: data.compartments,
                         names: Dictionary(data.fridges.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a }))
        }
        center.onOpenFood = { [weak self, weak center] item in
            guard let self else { return }
            if item.fridgeID == self.fridge.id {
                self.openFood(item.id, from: center)
            } else {
                self.switchFridge(to: item.fridgeID, then: .link(AppDeepLink(.food(item.id))))
            }
        }
        center.onOpenSettings = { [weak self, weak center] in self?.openNotificationSettings(from: center) }
        navigationController?.pushViewController(center, animated: true)
    }

    /// Opens a food's editor, or explains that it no longer exists (consumed / deleted) instead of crashing.
    func openFood(_ id: UUID, from presenter: UIViewController? = nil) {
        let host = presenter ?? navigationController?.topViewController ?? self
        switch FoodRoute.resolve(foodID: id, inventory: inventory) {
        case .editor:
            FoodEditorViewController.present(.edit(foodID: id), inventory: inventory, compartments: fridge.allCompartments,
                                             from: host.presentedViewController ?? host)
        case .missing:
            FoodActions.showError("這項食材已被食用或刪除。", on: host.presentedViewController ?? host)
        }
    }

    // MARK: - Fridges

    private func configureFridgeSelector() {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: "chevron.down", withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold))
        config.imagePlacement = .trailing
        config.imagePadding = 6
        config.contentInsets = .zero
        config.baseForegroundColor = Theme.Color.textPrimary
        config.titleLineBreakMode = .byTruncatingTail
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attrs in
            var attrs = attrs
            attrs.font = Theme.Font.title
            return attrs
        }
        fridgeSelector.configuration = config
        fridgeSelector.contentHorizontalAlignment = .leading
        fridgeSelector.showsMenuAsPrimaryAction = true
        fridgeSelector.accessibilityIdentifier = "home.fridgeSelector"
        fridgeSelector.accessibilityHint = "點兩下切換或管理冰箱"
        fridgeSelector.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // Built on every open, so names, the check mark and the limit are always current.
        fridgeSelector.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] completion in
            completion(self?.fridgeMenuElements() ?? [])
        }])
    }

    func fridgeMenuElements() -> [UIMenuElement] {
        let fridges = directory.fridges.map { fridge in
            UIAction(title: fridge.name, image: UIImage(systemName: "refrigerator"),
                     state: fridge.id == self.fridge.id ? .on : .off) { [weak self] _ in
                guard let self, fridge.id != self.fridge.id else { return }
                self.switchFridge(to: fridge.id, then: nil)
            }
        }
        let add = UIAction(title: "新增冰箱", image: UIImage(systemName: "plus")) { [weak self] _ in self?.addFridge() }
        if !directory.canAddFridge {
            add.attributes = .disabled
            add.subtitle = FridgePolicy.limitMessage
        }
        let manage = UIAction(title: "管理冰箱", image: UIImage(systemName: "slider.horizontal.3")) { [weak self] _ in
            guard let self, let management = self.makeFridgeManagement() else { return }
            self.navigationController?.pushViewController(management, animated: true)
        }
        return [UIMenu(options: .displayInline, children: fridges), UIMenu(options: .displayInline, children: [add, manage])]
    }

    func addFridge() {
        guard !isEditingLayout else { return }
        FridgeActions.presentAdd(directory: directory, copyFrom: fridge, from: navigationController ?? self) { [weak self] created in
            self?.switchFridge(to: created.id, then: nil)
        }
    }

    func makeFridgeManagement() -> UIViewController? {
        FridgeManagementViewController(directory: directory, currentFridgeID: { [weak self] in self?.fridge.id ?? UUID() },
                                       onSelect: { [weak self] id in self?.switchFridge(to: id, then: nil) })
    }

    /// Hands over to the scene delegate, which shows the chosen fridge (its own layout, door state and food)
    /// and remembers it for the next launch. Nothing of this fridge is changed.
    func switchFridge(to id: UUID, then route: ExternalRoute?) {
        guard !isEditingLayout else { return showRouteMessage("請先完成或取消隔層編輯") }
        onSwitchFridge?(id, route)
    }

    // MARK: - Settings & ads

    func openSettings() {
        guard !isEditingLayout else { return }
        let backup = BackupFlow(service: makeBackupService(),
                                syncsToCloud: { CloudSyncSettings.shared.isEnabled && CloudSyncMonitor.shared.isCloudActive }) { [weak self] failure in
            self?.onDataRestored?(failure)
        }
        let settings = SettingsViewController(entitlements: entitlements, ads: ads, notifications: notifications,
                                              makeFridgeManagement: { [weak self] in self?.makeFridgeManagement() },
                                              backup: backup)
        navigationController?.pushViewController(settings, animated: true)
    }

    @objc private func monetizationChanged() {
        prepareAdsIfNeeded()
        updateBanner()
    }

    /// Consent + SDK start, only for free users and only while the closed home is on screen
    /// (the consent form is presented from here).
    private func prepareAdsIfNeeded() {
        guard let ads, viewIfLoaded?.window != nil, presentedViewController == nil,
              navigationController?.topViewController === self else { return }
        Task { @MainActor in await ads.prepareIfNeeded(from: self) }
    }

    /// The screen currently showing, for ad placement rules.
    var currentScreen: AppScreen {
        if isEditingLayout { return .layoutEditing }
        return fridge.lastDoorState == .open ? .openFridge : .closedHome
    }

    /// Shows the banner only on the closed home, for eligible free users, when it fits; otherwise removes it.
    private func updateBanner() {
        guard let ads, let bannerContainer else { return }
        let reserved: CGFloat = bannerContainer.isLoaded ? 0 : Self.expectedBannerHeight
        let available = closedContainer.bounds.height == 0 ? .greatestFiniteMagnitude : closedContainer.bounds.height - reserved
        let allowed = ads.eligibility.allows(.closedHomeBanner, on: currentScreen, contentHeightAfterBanner: available)
        if allowed {
            bannerContainer.activate(width: footer.bounds.width > 0 ? footer.bounds.width : view.bounds.width - 2 * Theme.Metric.gutter,
                                     rootViewController: self)
        } else {
            // Premium, no consent, other screen, or no room: stop requesting and release the ad view.
            bannerContainer.deactivate()
        }
    }

    /// Conservative height reserved when checking whether a banner fits before it has loaded.
    static let expectedBannerHeight: CGFloat = 90

    var isShowingBanner: Bool { bannerContainer?.isLoaded == true && bannerContainer?.isHidden == false }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateBanner()
    }

    private func openNotificationSettings(from presenter: UIViewController?) {
        navigationController?.pushViewController(NotificationSettingsViewController(coordinator: notifications), animated: true)
    }

    // MARK: - External routes (widgets, notifications)

    /// Handles a widget link or notification tap. Every parameter is validated against current data;
    /// anything invalid lands on the fridge home with a short explanation. Unsaved work is never discarded:
    /// an open food editor or layout edit stays and the user is told to finish it first.
    func handle(_ route: ExternalRoute) {
        guard case let .link(link) = route else { return showRouteMessage("無法開啟這個連結，已回到冰箱") }
        if isEditingLayout { return showRouteMessage("請先完成或取消隔層編輯") }
        if let editor = presentedFoodEditor {
            // Repeated quick-add taps reuse the open add form instead of stacking another one.
            if case .quickAdd = link.destination, editor.isAddMode, (link.refrigeratorID ?? fridge.id) == fridge.id { return }
            return showRouteMessage("請先完成目前的食材編輯")
        }
        if let fridgeID = link.refrigeratorID, fridgeID != fridge.id {
            guard directory.contains(fridgeID) else {
                return returnHome { $0.showRouteMessage("找不到這台冰箱，已回到目前的冰箱") }
            }
            // Another fridge: switch first, then open the destination there (compartment / food are validated
            // against that fridge after the switch).
            return switchFridge(to: fridgeID, then: .link(AppDeepLink(link.destination)))
        }
        returnHome { home in
            switch link.destination {
            case .home:
                break
            case let .quickAdd(compartmentID):
                home.openQuickAdd(preferredCompartmentID: compartmentID)
            case let .reminders(storage, kind):
                home.openReminderCenter(kind: kind, storage: storage)
            case let .food(id):
                home.openFood(id)
            }
        }
    }

    /// Food editor anywhere in the presented chain (it may hold unsaved input).
    private var presentedFoodEditor: FoodEditorViewController? {
        var current = navigationController?.presentedViewController ?? presentedViewController
        while let controller = current {
            if let editor = (controller as? UINavigationController)?.viewControllers.compactMap({ $0 as? FoodEditorViewController }).first {
                return editor
            }
            current = controller.presentedViewController
        }
        return nil
    }

    /// Closes transient sheets (lists, search, settings) and pops to the fridge, then runs `then`.
    /// A single navigation stack is kept, so repeated links never duplicate screens.
    private func returnHome(then: @escaping (FridgeHomeViewController) -> Void) {
        let finish = { [weak self] in
            guard let self else { return }
            self.navigationController?.popToRootViewController(animated: false)
            then(self)
        }
        if let presented = navigationController?.presentedViewController ?? presentedViewController {
            presented.presentingViewController?.dismiss(animated: false, completion: finish) ?? finish()
        } else {
            finish()
        }
    }

    func showMessage(_ message: String) { showRouteMessage(message) }

    private func showRouteMessage(_ message: String) {
        let top = navigationController?.topViewController ?? self
        // On the fridge screen, stay clear of the 搜尋 / 新增食材 bar.
        ToastView.show(message, in: top.view, bottomInset: top === self ? 72 : 24)
    }

    /// Quick add from a widget: the regular add form (favorites, recents, continuous entry included),
    /// today's date, quantity 1, no expiry or reminder, and the requested or last-used compartment if it still exists.
    func openQuickAdd(preferredCompartmentID: UUID?) {
        let valid = Set(fridge.allCompartments.map(\.id))
        let compartment = preferredCompartmentID.flatMap { valid.contains($0) ? $0 : nil }
            ?? inventory.lastUsedCompartmentID(validIDs: valid)
        openFoodEditor(.add(compartmentID: compartment))
    }

    private func openSearch(mode: FoodSearchViewController.Scope = .all) {
        FoodSearchViewController.present(scope: mode, inventory: inventory,
                                         compartments: { [weak self] in self?.fridge.allCompartments ?? [] },
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
