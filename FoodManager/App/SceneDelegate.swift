import UIKit

/// Composition root: opens storage, then shows either the fridge or the recoverable storage-error screen.
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private(set) var home: FridgeHomeViewController?
    private lazy var persistence = Self.makePersistence()
    /// Built once from `MonetizationPolicy` (survives storage retries and fridge switches).
    private lazy var monetization = MonetizationServices.make(policy: .current, mode: persistence.mode)

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        window.overrideUserInterfaceStyle = .light // fixed warm palette
        window.tintColor = Theme.Color.stroke
        self.window = window
        start()
        window.makeKeyAndVisible()
        // Cold launch from a widget: delivered once the fridge screen is ready.
        if let url = connectionOptions.urlContexts.first?.url { AppNotificationRouter.shared.handle(url: url) }
    }

    /// Refunds, purchases on other devices or Ask-to-Buy approvals may have happened while in the background.
    func sceneWillEnterForeground(_ scene: UIScene) {
        guard let entitlements = monetization.entitlementObserver else { return }
        Task { await entitlements.refresh() }
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
        let home = FridgeHomeViewController(session: session, entitlements: monetization.entitlementsForUI, ads: monetization.ads)
        home.onSwitchFridge = { [weak self] id, route in self?.switchFridge(to: id, from: session, then: route) }
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

    /// Production always uses the persistent store. In-memory storage is chosen only explicitly:
    /// for the unit-test host and for UI tests launched with `--uitesting`.
    private static func makePersistence() -> AppPersistence {
        let environment = ProcessInfo.processInfo
        let isUnitTestHost = environment.environment["XCTestConfigurationFilePath"] != nil
        let isUITesting = environment.arguments.contains("--uitesting")
        return isUnitTestHost || isUITesting ? .inMemoryForTesting() : .production()
    }
}
