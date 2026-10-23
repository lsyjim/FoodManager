import UIKit

// MARK: - Loader abstraction

/// One interstitial at a time. The live implementation wraps Google's `InterstitialAd`; tests use a fake.
@MainActor
protocol InterstitialAdLoading: AnyObject {
    /// A loaded ad is waiting to be shown.
    var isReady: Bool { get }
    var isLoading: Bool { get }
    /// Loads one ad. Calls `completion(true)` once it is ready, `false` on failure or no fill.
    func load(unitID: String, completion: @escaping (Bool) -> Void)
    /// Presents the loaded ad. Returns false (and never calls `onDismiss`) if nothing was ready. Otherwise
    /// `onDismiss` runs exactly once: `true` after the user closed the ad, `false` if it failed to present.
    func present(from viewController: UIViewController, onDismiss: @escaping (_ shown: Bool) -> Void) -> Bool
}

// MARK: - Usage session

/// What "one usage session" means for the automatic interstitial: it starts when the app process starts and
/// continues across short trips to the background. Only after the app spent at least `timeout` in the background
/// does returning start a new session. (Plain foreground transitions never reset it.)
final class AdUsageSession {
    static let timeout: TimeInterval = 30 * 60
    private(set) var number = 1
    private var backgroundedAt: Date?

    func didEnterBackground(at date: Date) { backgroundedAt = date }

    func willEnterForeground(at date: Date) {
        if let backgroundedAt, date.timeIntervalSince(backgroundedAt) >= Self.timeout { number += 1 }
        backgroundedAt = nil
    }
}

// MARK: - Frequency rules

/// Persistent counters for automatic interstitials (manual ones from 設定 don't count).
protocol InterstitialHistoryStore: AnyObject {
    var lastAutomaticImpression: Date? { get set }
    /// "yyyy-MM-dd" in the user's calendar, with the number of automatic impressions that day.
    var dailyCount: (day: String, count: Int)? { get set }
}

final class UserDefaultsInterstitialHistory: InterstitialHistoryStore {
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var lastAutomaticImpression: Date? {
        get { defaults.object(forKey: "ads.lastAutomaticInterstitial") as? Date }
        set { defaults.set(newValue, forKey: "ads.lastAutomaticInterstitial") }
    }

    var dailyCount: (day: String, count: Int)? {
        get {
            guard let day = defaults.string(forKey: "ads.automaticInterstitialDay") else { return nil }
            return (day, defaults.integer(forKey: "ads.automaticInterstitialCount"))
        }
        set {
            defaults.set(newValue?.day, forKey: "ads.automaticInterstitialDay")
            defaults.set(newValue?.count ?? 0, forKey: "ads.automaticInterstitialCount")
        }
    }
}

/// Why an automatic interstitial was or wasn't shown (pure, testable).
enum AutomaticInterstitialDecision: Equatable {
    case show
    case adsNotAllowed
    case alreadyShownThisSession
    case dailyCapReached
    case coolingDown
    case fullscreenActive
    case notLoaded
    case userBusy
    /// The App Store rating prompt was requested moments ago.
    case reviewNearby
}

struct InterstitialFrequencyPolicy {
    static let dailyCap = 2
    static let cooldown: TimeInterval = 10 * 60

    var calendar = Calendar.current

    func dayKey(_ date: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    func decide(now: Date, adsAllowed: Bool, shownThisSession: Bool, history: InterstitialHistoryStore,
                fullscreenActive: Bool, loaded: Bool, presenterIdle: Bool) -> AutomaticInterstitialDecision {
        guard adsAllowed else { return .adsNotAllowed }
        guard !shownThisSession else { return .alreadyShownThisSession }
        if let daily = history.dailyCount, daily.day == dayKey(now), daily.count >= Self.dailyCap { return .dailyCapReached }
        if let last = history.lastAutomaticImpression, now.timeIntervalSince(last) < Self.cooldown, now >= last {
            return .coolingDown
        }
        guard !fullscreenActive else { return .fullscreenActive }
        guard presenterIdle else { return .userBusy }
        guard loaded else { return .notLoaded }
        return .show
    }

    func recordAutomaticImpression(at now: Date, in history: InterstitialHistoryStore) {
        let today = dayKey(now)
        let count = history.dailyCount.map { $0.day == today ? $0.count : 0 } ?? 0
        history.dailyCount = (today, count + 1)
        history.lastAutomaticImpression = now
    }
}

/// Result of 設定 → 觀看廣告.
enum ManualAdOutcome: Equatable {
    case shown
    /// No ad could be loaded (no fill, offline, consent, configuration). Nothing else happens.
    case unavailable
    /// Another full-screen ad is showing.
    case busy
}
