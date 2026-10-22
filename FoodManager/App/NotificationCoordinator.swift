import Foundation
import UserNotifications
import os

/// The slice of `UNUserNotificationCenter` the app uses; replaced by a test double in unit tests.
protocol NotificationClient: AnyObject {
    func authorizationStatus() async -> NotificationAuthorization
    func requestAuthorization() async throws -> Bool
    func pendingIdentifiers() async -> [String]
    func deliveredIdentifiers() async -> [String]
    func add(_ notification: PlannedNotification) async throws
    func removePending(identifiers: [String])
    func removeDelivered(identifiers: [String])
}

final class SystemNotificationClient: NotificationClient {
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) { self.center = center }

    func authorizationStatus() async -> NotificationAuthorization {
        switch await center.notificationSettings().authorizationStatus {
        case .authorized: return .authorized
        case .denied: return .denied
        case .provisional: return .provisional
        case .ephemeral: return .ephemeral
        case .notDetermined: return .notDetermined
        @unknown default: return .denied
        }
    }

    func requestAuthorization() async throws -> Bool {
        try await center.requestAuthorization(options: [.alert, .sound, .badge])
    }

    func pendingIdentifiers() async -> [String] {
        await center.pendingNotificationRequests().map(\.identifier)
    }

    func deliveredIdentifiers() async -> [String] {
        await center.deliveredNotifications().map(\.request.identifier)
    }

    func add(_ notification: PlannedNotification) async throws {
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        content.sound = .default
        content.threadIdentifier = notification.kind.rawValue
        content.userInfo = NotificationPayload.userInfo(for: notification)
        let trigger = UNCalendarNotificationTrigger(dateMatching: notification.fireDate, repeats: false)
        try await center.add(UNNotificationRequest(identifier: notification.identifier, content: content, trigger: trigger))
    }

    func removePending(identifiers: [String]) {
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    func removeDelivered(identifiers: [String]) {
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }
}

/// Single place that keeps pending notifications in sync with the inventory and preferences.
/// Call `reschedule()` after any food change, preference change, layout change or app activation.
@MainActor
final class NotificationCoordinator {
    /// Active food and compartments of *every* fridge. nil when they can't be read right now: then nothing
    /// is rescheduled (so a read error never cancels another fridge's reminders).
    typealias Snapshot = () -> (items: [FoodItem], compartments: [Compartment])?

    let preferencesStore: NotificationPreferencesStore
    private let client: NotificationClient
    private let snapshot: Snapshot
    private let planner: NotificationPlanner
    private let now: () -> Date
    private var pendingTask: Task<Void, Never>?
    private let logger = Logger(subsystem: "FoodManager.HowCode", category: "Notifications")

    init(client: NotificationClient, preferencesStore: NotificationPreferencesStore, planner: NotificationPlanner = NotificationPlanner(),
         now: @escaping () -> Date = Date.init, snapshot: @escaping Snapshot) {
        self.client = client
        self.preferencesStore = preferencesStore
        self.planner = planner
        self.now = now
        self.snapshot = snapshot
    }

    var preferences: NotificationPreferences { preferencesStore.load() }

    func authorizationStatus() async -> NotificationAuthorization { await client.authorizationStatus() }

    /// Asks the system for permission (only from an explicit user action) and reschedules on success.
    func requestAuthorization() async -> NotificationAuthorization {
        do {
            _ = try await client.requestAuthorization()
        } catch {
            logger.error("Notification authorization request failed: \(String(describing: error), privacy: .private)")
        }
        await reschedule()
        return await client.authorizationStatus()
    }

    /// Coalesces bursts of changes into one reschedule. Reschedules never overlap: each waits for the
    /// previous one (cancellation alone doesn't stop a running task), and superseded ones are skipped.
    func scheduleUpdate() {
        let previous = pendingTask
        previous?.cancel()
        pendingTask = Task { [weak self] in
            await previous?.value
            guard !Task.isCancelled else { return }
            await self?.reschedule()
        }
    }

    /// Replaces this app's pending food notifications with the current plan. Returns what is now scheduled.
    @discardableResult
    func reschedule() async -> [PlannedNotification] {
        guard let (items, compartments) = snapshot() else { return [] }
        let ours = await client.pendingIdentifiers().filter { $0.hasPrefix(PlannedNotification.identifierPrefix) }
        let activeIDs = Set(items.filter(\.isActive).map(\.id))

        // Delivered notifications for food that was eaten or deleted are cleared from Notification Center.
        let staleDelivered = await client.deliveredIdentifiers().filter {
            guard let id = PlannedNotification.foodID(fromIdentifier: $0) else { return false }
            return !activeIDs.contains(id)
        }
        if !staleDelivered.isEmpty { client.removeDelivered(identifiers: staleDelivered) }

        guard await client.authorizationStatus().canSchedule else {
            if !ours.isEmpty { client.removePending(identifiers: ours) }
            return []
        }
        let plan = planner.plan(items: items, compartments: compartments, preferences: preferences, now: now())
        let planned = Set(plan.map(\.identifier))
        let outdated = ours.filter { !planned.contains($0) }
        if !outdated.isEmpty { client.removePending(identifiers: outdated) }
        var scheduled: [PlannedNotification] = []
        for notification in plan {
            do {
                try await client.add(notification) // same identifier replaces → never duplicates
                scheduled.append(notification)
            } catch {
                logger.error("Scheduling a notification failed: \(String(describing: error), privacy: .private)")
            }
        }
        return scheduled
    }
}
