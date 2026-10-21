import UIKit

/// Composition root: opens storage, then shows either the fridge or the recoverable storage-error screen.
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private(set) var home: FridgeHomeViewController?
    private lazy var persistence = Self.makePersistence()

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        window.overrideUserInterfaceStyle = .light // fixed warm palette
        window.tintColor = Theme.Color.stroke
        self.window = window
        start()
        window.makeKeyAndVisible()
    }

    /// (Re)attempts to open storage. Called at launch and by the error screen's retry button.
    private func start() {
        switch AppBootstrap.start(persistence) {
        case let .success(session):
            let home = FridgeHomeViewController(session: session)
            self.home = home
            let navigation = UINavigationController(rootViewController: home)
            navigation.navigationBar.tintColor = Theme.Color.stroke
            window?.rootViewController = navigation
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

    /// Production always uses the persistent store. In-memory storage is chosen only explicitly:
    /// for the unit-test host and for UI tests launched with `--uitesting`.
    private static func makePersistence() -> AppPersistence {
        let environment = ProcessInfo.processInfo
        let isUnitTestHost = environment.environment["XCTestConfigurationFilePath"] != nil
        let isUITesting = environment.arguments.contains("--uitesting")
        return isUnitTestHost || isUITesting ? .inMemoryForTesting() : .production()
    }
}
