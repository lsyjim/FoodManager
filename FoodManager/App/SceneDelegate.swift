import CloudKit
import SwiftData
import UIKit

/// Composition root: opens storage, then shows either the fridge or the recoverable storage-error screen.
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private(set) var home: FridgeHomeViewController?
    private lazy var persistence = Self.makePersistence()
    private var currentSession: AppSession?
    /// Native App Store rating prompt (real data only: tests and UI tests never count usage or ask).
    private lazy var review: ReviewRequestCoordinator? = persistence.mode == .persistent ? ReviewRequestCoordinator() : nil
    private var reviewCheck: Task<Void, Never>?
    private lazy var cloudSync: CloudSyncCoordinator = {
        let coordinator = CloudSyncCoordinator()
        coordinator.currentSession = { [weak self] in self?.currentSession }
        coordinator.canRefresh = { [weak self] in self?.home?.canBeRebuilt ?? false }
        coordinator.refresh = { [weak self] session in self?.reloadAfterCloudImport(from: session) }
        coordinator.presentAccountNotice = { [weak self] in self?.presentAccountNoticeIfNeeded() }
        return coordinator
    }()
    /// Shared refrigerators (Phase 5D): only while `SharingPolicy` is active and iCloud sync runs. Release 1.0 never
    /// creates them.
    private var sharedEngine: SharedSyncEngine?
    private var sharedInventory: SharedInventory?
    /// Built once from `MonetizationPolicy` (survives storage retries and fridge switches).
    private lazy var monetization = MonetizationServices.make(policy: .current, mode: persistence.mode)

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        window.overrideUserInterfaceStyle = .light // fixed warm palette
        window.tintColor = Theme.Color.stroke
        self.window = window
        NotificationCenter.default.addObserver(forName: .cloudSyncSettingDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.reopenStorage()
        }
        start()
        window.makeKeyAndVisible()
        review?.recordLaunch()
        NotificationCenter.default.addObserver(forName: .foodItemCreated, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.foodWasCreated() }
        }
        // Cold launch from a widget: delivered once the fridge screen is ready.
        if let url = connectionOptions.urlContexts.first?.url { AppNotificationRouter.shared.handle(url: url) }
    }

    /// Refunds, purchases on other devices or Ask-to-Buy approvals may have happened while in the background.
    func sceneWillEnterForeground(_ scene: UIScene) {
        monetization.ads?.appWillEnterForeground()
        if persistence.mode == .persistent { cloudSync.checkAccount() }
        guard let entitlements = monetization.entitlementObserver else { return }
        Task { await entitlements.refresh() }
    }

    /// Keeps the local protection copy current (policy A: recoverable after an iCloud sign-out or account change).
    func sceneDidEnterBackground(_ scene: UIScene) {
        monetization.ads?.appDidEnterBackground()
        if persistence.mode == .persistent { cloudSync.refreshProtectionSnapshot() }
    }

    /// Widget tap while running or restored from the background.
    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        guard let url = URLContexts.first?.url else { return }
        AppNotificationRouter.shared.handle(url: url)
    }

    /// Someone opened a shared-fridge link. Ignored entirely while sharing is off (never accepted, no paywall);
    /// requesting access as a participant arrives in Phase 5D-4.
    func windowScene(_ windowScene: UIWindowScene, userDidAcceptCloudKitShareWith metadata: CKShare.Metadata) {
        guard SharingPolicy.current.joinGate == .allowed, currentSession?.sharing != nil else { return }
        home?.showMessage("這個版本還不能加入共享冰箱。")
    }

    /// (Re)attempts to open storage. Called at launch and by the error screen's retry button.
    private func start() {
        switch AppBootstrap.start(persistence, sharing: { [weak self] in self?.makeSharing(container: $0) }) {
        case let .success(session):
            show(session)
            if persistence.mode == .persistent {
                cloudSync.didOpen(cloudActive: persistence.isCloudActive, problem: persistence.cloudProblem)
                presentAccountNoticeIfNeeded()
            }
        case .failure:
            home = nil
            if let errorScreen = window?.rootViewController as? StorageUnavailableViewController {
                errorScreen.showRetryFailed()
            } else {
                let errorScreen = StorageUnavailableViewController()
                errorScreen.onRetry = { [weak self] in self?.start() }
                window?.rootViewController = errorScreen
            }
        }
    }

    /// Shows the home screen for the session's selected fridge.
    private func show(_ session: AppSession, animated: Bool = false) {
        currentSession = session
        let home = FridgeHomeViewController(session: session, entitlements: monetization.entitlementsForUI, ads: monetization.ads)
        home.onSwitchFridge = { [weak self] id, route in self?.switchFridge(to: id, from: session, then: route) }
        home.onDataRestored = { [weak self] failure in self?.reloadAfterRestore(from: session, failure: failure) }
        self.home = home
        let navigation = UINavigationController(rootViewController: home)
        navigation.navigationBar.tintColor = Theme.Color.stroke
        guard let window else { return }
        window.rootViewController = navigation
        if animated && !UIAccessibility.isReduceMotionEnabled {
            UIView.transition(with: window, duration: 0.25, options: .transitionCrossDissolve, animations: nil)
        }
    }

    /// Selects another fridge (remembered for the next launch) and shows it, then delivers `route` there.
    private func switchFridge(to id: UUID, from session: AppSession, then route: ExternalRoute?) {
        do {
            show(try session.selecting(id), animated: true)
            if let route { AppNotificationRouter.shared.route(route) }
        } catch {
            home?.showMessage("無法切換冰箱，請再試一次。")
        }
    }

    /// A restore replaced the stored data: rebuild everything (fresh contexts on the same container, never a
    /// second one), so no screen keeps showing old data. Then reschedule notifications and refresh widgets.
    private func reloadAfterRestore(from session: AppSession, failure: String?) {
        switch AppBootstrap.makeSession(container: session.container, mode: session.mode, selection: session.selection,
                                         sharing: session.sharing) {
        case let .success(restored):
            show(restored, animated: true)
            guard let home else { return }
            home.loadViewIfNeeded()
            Task { @MainActor [weak home] in
                let problems = await home?.syncAfterRestore() ?? []
                guard let home else { return }
                if let failure {
                    let alert = UIAlertController(title: "沒有還原", message: failure, preferredStyle: .alert)
                    alert.addAction(UIAlertAction(title: "好", style: .default))
                    home.present(alert, animated: true)
                } else if problems.isEmpty {
                    home.showMessage("已還原備份")
                } else {
                    home.showMessage("已還原備份，但\(problems.joined(separator: "與"))暫時沒有更新，稍後會自動再試")
                }
            }
        case .failure:
            // The restored data is saved; only this screen couldn't be rebuilt.
            home?.showMessage("資料已還原，但畫面無法重新載入，請關閉並重新開啟 App")
        }
    }

    /// iCloud delivered changes: rebuild from the same container (fresh contexts) so every screen, the reminder
    /// schedule and the widget snapshots reflect them. Only called while the user isn't in the middle of something.
    private func reloadAfterCloudImport(from session: AppSession) {
        guard case let .success(updated) = AppBootstrap.makeSession(container: session.container, mode: session.mode,
                                                                    selection: session.selection, sharing: session.sharing) else { return }
        show(updated)
    }

    /// Turning iCloud sync on/off reopens the store with the new setting. The old session is released first so
    /// two containers never mirror the same store.
    private func reopenStorage() {
        cloudSync.stop()
        sharedEngine = nil
        sharedInventory = nil
        window?.rootViewController = UIViewController()
        home = nil
        currentSession = nil
        persistence = Self.makePersistence()
        start()
    }

    /// The shared-fridge pipeline for an opened container, or nil (sharing off, tests, or iCloud sync not running).
    private func makeSharing(container: ModelContainer) -> SharingService? {
        let policy = SharingPolicy.current
        guard persistence.isCloudActive else { return nil }
        if sharedEngine == nil {
            sharedEngine = SharedSyncEngine.make(policy: policy, mode: persistence.mode, cloudSyncEnabled: CloudSyncSettings.shared.isEnabled)
            sharedEngine?.onChange = { [weak self] in self?.sharedDataChanged() }
            sharedEngine?.start()
        }
        guard let engine = sharedEngine else { return nil }
        let inventory = sharedInventory ?? SharedInventory(store: engine.store)
        inventory.onLocalChange = { [weak engine] change in engine?.enqueue(change) }
        sharedInventory = inventory
        return SharingService(policy: policy, inventory: inventory, cloud: CloudKitSharingCloud(engine: engine),
                              personal: SwiftDataFridgeStore(container: container),
                              hasPremium: { [weak self] in self?.monetization.entitlementObserver?.isPremium ?? false },
                              snapshots: .shared)
    }

    /// Shared-fridge changes arrived: rebuild like after an iCloud import, at a calm moment only.
    private func sharedDataChanged() {
        guard let session = currentSession, home?.canBeRebuilt == true else { return }
        reloadAfterCloudImport(from: session)
    }

    /// Policy A: after an iCloud account change the data shown belongs to the new account. Explain once where the
    /// previous data is and how to restore it (restoring is always the user's explicit choice).
    private func presentAccountNoticeIfNeeded() {
        guard CloudSyncSettings.shared.hasPendingAccountNotice, let home, home.canBeRebuilt else { return }
        CloudSyncSettings.shared.hasPendingAccountNotice = false
        let alert = UIAlertController(title: "iCloud 帳號已變更",
                                      message: "冰箱管理員現在顯示這個 iCloud 帳號的資料。原本的資料保留在這台裝置的保護副本中，需要時可到「設定 → 資料管理 → iCloud 自動同步」還原（還原的資料會同步到目前這個帳號）。",
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default))
        home.present(alert, animated: true)
    }

    /// A food record was saved. Counts it, then — at a calm moment back on the fridge home (editor closed, nothing
    /// on top, no ad nearby) — lets the coordinator decide whether to ask iOS for the rating prompt. Checks a few
    /// times while e.g. a continuous-entry editor is still open, then gives up until the next food is added.
    private func foodWasCreated() {
        guard let review else { return }
        review.recordSuccessfulFoodCreation()
        reviewCheck?.cancel()
        reviewCheck = Task { @MainActor [weak self] in
            for _ in 0..<15 {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled, let self, let review = self.review else { return }
                let moment = ReviewMoment(appIsActive: UIApplication.shared.applicationState == .active,
                                          scene: self.window?.windowScene,
                                          homeIsIdle: self.home?.canBeRebuilt == true && self.home?.isAdOnScreen == false)
                if review.considerRequest(moment) != .userBusy { return }
            }
        }
    }

    /// Production always uses the persistent store. In-memory storage is chosen only explicitly:
    /// for the unit-test host and for UI tests launched with `--uitesting`.
    private static func makePersistence() -> AppPersistence {
        let environment = ProcessInfo.processInfo
        let isUnitTestHost = environment.environment["XCTestConfigurationFilePath"] != nil
        let isUITesting = environment.arguments.contains("--uitesting")
        return isUnitTestHost || isUITesting ? .inMemoryForTesting() : .production()
    }
}
