import SwiftData
import UIKit
import os

/// Composition root: builds the store and the home screen in code (no storyboards).
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        window.overrideUserInterfaceStyle = .light // fixed warm palette in Phase 1
        window.tintColor = Theme.Color.stroke
        let container = Self.makeContainer()
        window.rootViewController = FridgeHomeViewController(store: SwiftDataFridgeStore(container: container),
                                                             foodStore: SwiftDataFoodStore(container: container))
        window.makeKeyAndVisible()
        self.window = window
    }

    /// One container shared by the fridge and food stores.
    private static func makeContainer() -> ModelContainer {
        let isUnitTesting = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        do {
            return try SwiftDataFridgeStore.makeContainer(inMemory: isUnitTesting)
        } catch {
            Logger(subsystem: "FoodManager.HowCode", category: "App")
                .fault("Persistent store unavailable, using in-memory store: \(String(describing: error))")
            do {
                return try SwiftDataFridgeStore.makeContainer(inMemory: true)
            } catch {
                fatalError("Unable to create even an in-memory store: \(error)")
            }
        }
    }
}
