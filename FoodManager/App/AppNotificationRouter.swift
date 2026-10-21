import UIKit
import UserNotifications

/// Receives notification taps (also when the tap launched the app) and opens the matching food.
/// A tap that arrives before the fridge screen exists is kept until it is ready.
final class AppNotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = AppNotificationRouter()

    private weak var home: FridgeHomeViewController?
    private var pendingFoodID: UUID?

    /// Called whenever a fridge screen becomes available (launch or storage retry).
    func attach(_ home: FridgeHomeViewController) {
        self.home = home
        deliverPending()
    }

    /// Routes a notification payload. Returns false if it isn't one of ours.
    @discardableResult
    func handle(userInfo: [AnyHashable: Any]) -> Bool {
        guard let foodID = NotificationPayload.foodID(from: userInfo) else { return false }
        pendingFoodID = foodID
        deliverPending()
        return true
    }

    private func deliverPending() {
        guard let foodID = pendingFoodID, let home, home.isViewLoaded else { return }
        pendingFoodID = nil
        home.openFood(fromNotification: foodID)
    }

    // MARK: UNUserNotificationCenterDelegate

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let userInfo = response.notification.request.content.userInfo
        DispatchQueue.main.async {
            self.handle(userInfo: userInfo)
            completionHandler()
        }
    }

    /// Show reminders as banners even while the app is open.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }
}
