import UIKit

/// Composition root: opens storage, then shows either the fridge or the recoverable storage-error screen.
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private(set) var home: FridgeHomeViewController?
    private lazy var persistence = Self.makePersistence()
    private var currentSession: AppSession?
    private lazy var cloudSync: CloudSyncCoordinator = {
        let coordinator = CloudSyncCoordinator()
        coordinator.currentSession = { [weak self] in self?.currentSession }
        coordinator.canRefresh = { [weak self] in self?.home?.canBeRebuilt ?? false }
        coordinator.refresh = { [weak self] session in self?.reloadAfterCloudImport(from: session) }
        coordinator.presentAccountNotice = { [weak self] in self?.presentAccountNoticeIfNeeded() }
        return coordinator
    }()
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
        // Cold launch from a widget: delivered once the fridge screen is ready.
        if let url = connectionOptions.urlContexts.first?.url { AppNotificationRouter.shared.handle(url: url) }
    }

    /// Refunds, purchases on other devices or Ask-to-Buy approvals may have happened while in the background.
    func sceneWillEnterForeground(_ scene: UIScene) {
        if persistence.mode == .persistent { cloudSync.checkAccount() }
        guard let entitlements = monetization.entitlementObserver else { return }
        Task { await entitlements.refresh() }
    }

    /// Keeps the local protection copy current (policy A: recoverable after an iCloud sign-out or account change).
    func sceneDidEnterBackground(_ scene: UIScene) {
        if persistence.mode == .persistent { cloudSync.refreshProtectionSnapshot() }
    }

    /// Widget tap while running or restored from the background.
    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        guard let url = URLContexts.first?.url else { return }
        AppNotificationRouter.shared.handle(url: url)
    }

    /// (Re)attempts to open storage. Called at launch and by the error screen's retry button.
    private func start() {
        switch AppBootstrap.start(persistence) {
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
        switch AppBootstrap.makeSession(container: session.container, mode: session.mode, selection: session.selection) {
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
                                                                    selection: session.selection) else { return }
        show(updated)
    }

    /// Turning iCloud sync on/off reopens the store with the new setting. The old session is released first so
    /// two containers never mirror the same store.
    private func reopenStorage() {
        cloudSync.stop()
        window?.rootViewController = UIViewController()
        home = nil
        currentSession = nil
        persistence = Self.makePersistence()
        start()
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

    /// Production always uses the persistent store. In-memory storage is chosen only explicitly:
    /// for the unit-test host and for UI tests launched with `--uitesting`.
    private static func makePersistence() -> AppPersistence {
        let environment = ProcessInfo.processInfo
        let isUnitTestHost = environment.environment["XCTestConfigurationFilePath"] != nil
        let isUITesting = environment.arguments.contains("--uitesting")
        return isUnitTestHost || isUITesting ? .inMemoryForTesting() : .production()
    }
}
