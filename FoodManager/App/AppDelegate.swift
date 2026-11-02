import CloudKit
import UIKit
import UserNotifications

extension Notification.Name {
    /// A CloudKit push for this app's container arrived (shared-fridge changes).
    static let cloudKitPushReceived = Notification.Name("CloudKitPushReceived")
}

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // Must be set before launch finishes so a notification tap that launched the app is delivered.
        UNUserNotificationCenter.current().delegate = AppNotificationRouter.shared
        return true
    }

    /// Silent CloudKit pushes (registered only while shared fridges are on): fetch the changes right away instead of
    /// waiting for the fallback fetch.
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        guard CKNotification(fromRemoteNotificationDictionary: userInfo) != nil else { return completionHandler(.noData) }
        NotificationCenter.default.post(name: .cloudKitPushReceived, object: nil)
        completionHandler(.newData)
    }

    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: "Default", sessionRole: connectingSceneSession.role)
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }
}
