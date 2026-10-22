import UIKit
import UserNotifications

/// A navigation request from outside the app (widget link or notification tap).
enum ExternalRoute: Equatable {
    case link(AppDeepLink)
    /// A `foodmanager://` URL that failed validation: show home with a message.
    case invalidLink
}

/// Routes notification taps and widget deep links (cold launch, running, or restored from background).
/// A request that arrives before the fridge screen exists is kept until it is ready; a newer request
/// replaces an older pending one, so repeated taps never stack screens.
final class AppNotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = AppNotificationRouter()

    private weak var home: FridgeHomeViewController?
    private(set) var pending: ExternalRoute?

    /// Called whenever a fridge screen becomes available (launch or storage retry).
    func attach(_ home: FridgeHomeViewController) {
        self.home = home
        deliverPending()
    }

    /// Routes a notification payload. Returns false if it isn't one of ours.
    @discardableResult
    func handle(userInfo: [AnyHashable: Any]) -> Bool {
        guard let foodID = NotificationPayload.foodID(from: userInfo) else { return false }
        route(.link(AppDeepLink(.food(foodID))))
        return true
    }

    /// Routes an opened URL. Returns false for URLs that aren't ours (other schemes).
    @discardableResult
    func handle(url: URL) -> Bool {
        guard url.scheme?.lowercased() == AppDeepLink.scheme else { return false }
        route(AppDeepLink(url: url).map(ExternalRoute.link) ?? .invalidLink)
        return true
    }

    func route(_ route: ExternalRoute) {
        pending = route
        deliverPending()
    }

    private var activationObserver: NSObjectProtocol?

    private func deliverPending() {
        guard pending != nil, let home, home.isViewLoaded else { return }
        // Links arrive while the app is still activating; navigating (and showing feedback) then would
        // run its animations invisibly. Wait for the app to become active first.
        if UIApplication.shared.applicationState != .active {
            guard activationObserver == nil else { return }
            activationObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                if let observer = self.activationObserver { NotificationCenter.default.removeObserver(observer) }
                self.activationObserver = nil
                self.deliverPending()
            }
            return
        }
        guard let route = pending else { return }
        pending = nil
        home.handle(route)
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
