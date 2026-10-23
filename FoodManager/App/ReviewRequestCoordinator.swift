import StoreKit
import UIKit

// MARK: - Shared full-screen presentation gate

/// One place that knows about system-level full-screen moments (interstitial ads, the review request), so they
/// never collide or follow each other immediately.
final class FullscreenPresentationGate {
    static let shared = FullscreenPresentationGate()
    /// Minimum quiet time between an interstitial and a review request (either order).
    static let separation: TimeInterval = 60

    private(set) var isAdOnScreen = false
    private(set) var lastAdEnded: Date?
    private(set) var lastReviewRequest: Date?

    func adWillPresent() { isAdOnScreen = true }
    func adDidEnd(at date: Date) {
        isAdOnScreen = false
        lastAdEnded = date
    }
    func reviewRequested(at date: Date) { lastReviewRequest = date }

    func canRequestReview(now: Date) -> Bool {
        guard !isAdOnScreen else { return false }
        if let lastAdEnded, now.timeIntervalSince(lastAdEnded) < Self.separation { return false }
        return true
    }

    func canPresentAd(now: Date) -> Bool {
        guard let lastReviewRequest else { return true }
        return now.timeIntervalSince(lastReviewRequest) >= Self.separation
    }
}

// MARK: - Review history

/// Persistent usage counters for the review request (survive relaunches; never reset by the app).
protocol ReviewHistoryStore: AnyObject {
    var firstLaunch: Date? { get set }
    var launchCount: Int { get set }
    var successfulFoodCreations: Int { get set }
    var lastRequestAttempt: Date? { get set }
}

final class UserDefaultsReviewHistory: ReviewHistoryStore {
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var firstLaunch: Date? {
        get { defaults.object(forKey: "review.firstLaunch") as? Date }
        set { defaults.set(newValue, forKey: "review.firstLaunch") }
    }
    var launchCount: Int {
        get { defaults.integer(forKey: "review.launchCount") }
        set { defaults.set(newValue, forKey: "review.launchCount") }
    }
    var successfulFoodCreations: Int {
        get { defaults.integer(forKey: "review.foodCreations") }
        set { defaults.set(newValue, forKey: "review.foodCreations") }
    }
    var lastRequestAttempt: Date? {
        get { defaults.object(forKey: "review.lastRequestAttempt") as? Date }
        set { defaults.set(newValue, forKey: "review.lastRequestAttempt") }
    }
}

// MARK: - Request API

/// The native StoreKit review request, behind a protocol so tests never call it. iOS decides whether the
/// dialog actually appears (at most a few times a year; never in TestFlight) and doesn't tell the app.
protocol ReviewRequesting {
    @MainActor func requestReview(in scene: UIWindowScene)
}

struct StoreKitReviewRequester: ReviewRequesting {
    @MainActor func requestReview(in scene: UIWindowScene) { AppStore.requestReview(in: scene) }
}

// MARK: - Coordinator

/// What the screen looks like when a review request is considered.
struct ReviewMoment {
    var appIsActive: Bool
    var scene: UIWindowScene?
    /// The fridge home is on screen with nothing on top (no editor, sheet, alert, restore, layout editing…).
    var homeIsIdle: Bool
}

enum ReviewDecision: Equatable {
    case request
    case notEnoughDays
    case notEnoughLaunches
    case notEnoughFoodCreated
    case coolingDown
    case alreadyAttemptedThisSession
    case userBusy
    case adNearby
    case noActiveScene
}

/// Decides when to ask iOS for the native rating prompt: only at a calm moment after a successful food entry,
/// for people who have used the app for a while. Never asks for a particular rating, never rewards or gates
/// anything, and never claims the prompt was shown (StoreKit doesn't say).
@MainActor
final class ReviewRequestCoordinator {
    static let minimumDays: TimeInterval = 3 * 24 * 3600
    static let minimumLaunches = 5
    static let minimumFoodCreations = 5
    static let cooldown: TimeInterval = 90 * 24 * 3600

    private let history: ReviewHistoryStore
    private let requester: ReviewRequesting
    private let gate: FullscreenPresentationGate
    private let now: () -> Date
    private var attemptedThisSession = false
    private(set) var lastDecision: ReviewDecision?

    init(history: ReviewHistoryStore = UserDefaultsReviewHistory(), requester: ReviewRequesting = StoreKitReviewRequester(),
         gate: FullscreenPresentationGate = .shared, now: @escaping () -> Date = Date.init) {
        self.history = history
        self.requester = requester
        self.gate = gate
        self.now = now
    }

    /// Once per process launch (the real app only; tests and UI tests never record usage).
    func recordLaunch() {
        if history.firstLaunch == nil { history.firstLaunch = now() }
        history.launchCount += 1
    }

    func recordSuccessfulFoodCreation() {
        history.successfulFoodCreations += 1
    }

    func decide(_ moment: ReviewMoment) -> ReviewDecision {
        let now = now()
        guard let first = history.firstLaunch, now.timeIntervalSince(first) >= Self.minimumDays else { return .notEnoughDays }
        guard history.launchCount >= Self.minimumLaunches else { return .notEnoughLaunches }
        guard history.successfulFoodCreations >= Self.minimumFoodCreations else { return .notEnoughFoodCreated }
        if let last = history.lastRequestAttempt, now.timeIntervalSince(last) < Self.cooldown { return .coolingDown }
        guard !attemptedThisSession else { return .alreadyAttemptedThisSession }
        guard moment.homeIsIdle else { return .userBusy }
        guard gate.canRequestReview(now: now) else { return .adNearby }
        guard moment.appIsActive, let scene = moment.scene, scene.activationState == .foregroundActive else { return .noActiveScene }
        return .request
    }

    /// Asks iOS for the rating prompt if every rule allows it. Returns the decision (an attempt, not a display).
    @discardableResult
    func considerRequest(_ moment: ReviewMoment) -> ReviewDecision {
        let decision = decide(moment)
        lastDecision = decision
        guard decision == .request, let scene = moment.scene else { return decision }
        attemptedThisSession = true
        history.lastRequestAttempt = now()
        gate.reviewRequested(at: now())
        requester.requestReview(in: scene)
        return decision
    }
}

// MARK: - Settings link

/// The App Store "write a review" page. The numeric Apple ID comes from App Store Connect (App Information →
/// Apple ID) via the `APP_STORE_ID` build setting; until it is set, the link is unavailable.
enum AppStoreReviewLink {
    static func url(appStoreID: String?) -> URL? {
        guard let id = appStoreID?.trimmingCharacters(in: .whitespaces), !id.isEmpty, id.allSatisfy(\.isNumber) else { return nil }
        return URL(string: "https://apps.apple.com/app/id\(id)?action=write-review")
    }

    static var configured: URL? {
        url(appStoreID: Bundle.main.object(forInfoDictionaryKey: "FMAppStoreID") as? String)
    }
}
