import UIKit
import XCTest
@testable import FoodManager

final class MemoryReviewHistory: ReviewHistoryStore {
    var firstLaunch: Date?
    var launchCount = 0
    var successfulFoodCreations = 0
    var lastRequestAttempt: Date?
}

@MainActor
final class FakeReviewRequester: ReviewRequesting {
    private(set) var requests = 0
    func requestReview(in scene: UIWindowScene) { requests += 1 }
}

/// Phase 5A: native App Store rating request (eligibility, timing, cooldown, ad separation) and the Settings link.
@MainActor
final class ReviewRequestTests: XCTestCase {
    private var clock = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private var history: MemoryReviewHistory!
    private var requester: FakeReviewRequester!
    private var gate: FullscreenPresentationGate!
    private var scene: UIWindowScene!

    override func setUp() async throws {
        history = MemoryReviewHistory()
        requester = FakeReviewRequester()
        gate = FullscreenPresentationGate()
        // The test host's own scene (foreground active while tests run).
        scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
    }

    private func coordinator() -> ReviewRequestCoordinator {
        ReviewRequestCoordinator(history: history, requester: requester, gate: gate, now: { [unowned self] in self.clock })
    }

    private var calm: ReviewMoment { ReviewMoment(appIsActive: true, scene: scene, homeIsIdle: true) }

    /// 3+ days, 5 launches, 5 foods.
    private func makeEligible(_ review: ReviewRequestCoordinator) {
        for _ in 0..<5 { review.recordLaunch() }
        for _ in 0..<5 { review.recordSuccessfulFoodCreation() }
        clock += 3 * 24 * 3600
    }

    // 1, 2
    func testFirstLaunchIsRememberedAndThreeDaysAreRequired() {
        let review = coordinator()
        XCTAssertEqual(review.decide(calm), .notEnoughDays, "never on a first launch")
        review.recordLaunch()
        XCTAssertEqual(history.firstLaunch, clock)
        let first = clock
        clock += 3600
        review.recordLaunch()
        XCTAssertEqual(history.firstLaunch, first, "the first launch date is never overwritten")
        for _ in 0..<5 { review.recordLaunch(); review.recordSuccessfulFoodCreation() }
        clock = first + 3 * 24 * 3600 - 1
        XCTAssertEqual(review.decide(calm), .notEnoughDays)
        clock += 1
        XCTAssertEqual(review.decide(calm), .request)
    }

    // 3, 4
    func testFiveLaunchesAndFiveFoodsAreRequired() {
        let review = coordinator()
        for _ in 0..<4 { review.recordLaunch() }
        for _ in 0..<5 { review.recordSuccessfulFoodCreation() }
        clock += 4 * 24 * 3600
        XCTAssertEqual(review.decide(calm), .notEnoughLaunches)
        review.recordLaunch()
        history.successfulFoodCreations = 4
        XCTAssertEqual(review.decide(calm), .notEnoughFoodCreated)
        review.recordSuccessfulFoodCreation()
        XCTAssertEqual(review.decide(calm), .request)
    }

    // 5
    func testOnlySuccessfulCreationsPostTheCreationEvent() throws {
        let container = try SwiftDataFridgeStore.makeContainer(inMemory: true)
        let fridge = try SwiftDataFridgeStore(container: container).loadAll()[0].fridge
        let flaky = FlakyFoodStore(base: SwiftDataFoodStore(container: container))
        let inventory = FoodInventoryService(store: flaky, fridgeID: fridge.id, compartments: { fridge.allCompartments })
        var created = 0
        let observer = NotificationCenter.default.addObserver(forName: .foodItemCreated, object: inventory, queue: nil) { _ in created += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }
        var draft = FoodDraft(compartmentID: fridge.cabinetCompartments[0].id)
        draft.name = ""
        XCTAssertThrowsError(try inventory.add(draft), "invalid input")
        draft.name = "牛奶"
        flaky.failWrites = true
        XCTAssertThrowsError(try inventory.add(draft), "save failure")
        XCTAssertEqual(created, 0)
        flaky.failWrites = false
        let item = try inventory.add(draft)
        XCTAssertEqual(created, 1)
        try inventory.update(item.id, with: draft)
        try inventory.markConsumed(item.id)
        _ = try inventory.restore(item.id)
        XCTAssertEqual(created, 1, "edits, consumption and restores aren't creations")
    }

    // 6, 12, 13
    func testNinetyDayCooldownSurvivesRelaunchAndNoDuplicates() {
        var review = coordinator()
        makeEligible(review)
        XCTAssertEqual(review.considerRequest(calm), .request)
        XCTAssertEqual(requester.requests, 1)
        XCTAssertEqual(review.considerRequest(calm), .coolingDown, "never twice in a row")
        clock += 30 * 24 * 3600
        review = coordinator() // relaunch: history is persistent
        review.recordLaunch()
        XCTAssertEqual(review.considerRequest(calm), .coolingDown)
        clock += 60 * 24 * 3600
        XCTAssertEqual(review.considerRequest(calm), .request, "after 90 days")
        XCTAssertEqual(review.considerRequest(calm), .coolingDown)
        XCTAssertEqual(requester.requests, 2)
    }

    func testUserDefaultsHistoryPersists() {
        let suite = "Review-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let a = UserDefaultsReviewHistory(defaults: defaults)
        a.firstLaunch = clock
        a.launchCount = 7
        a.successfulFoodCreations = 9
        a.lastRequestAttempt = clock
        let b = UserDefaultsReviewHistory(defaults: defaults)
        XCTAssertEqual(b.firstLaunch, clock)
        XCTAssertEqual(b.launchCount, 7)
        XCTAssertEqual(b.successfulFoodCreations, 9)
        XCTAssertEqual(b.lastRequestAttempt, clock)
    }

    // 7, 9, 14
    func testOnlyAtACalmMomentInAnActiveScene() {
        let review = coordinator()
        makeEligible(review)
        XCTAssertEqual(review.considerRequest(ReviewMoment(appIsActive: true, scene: scene, homeIsIdle: false)), .userBusy,
                       "editor, magnet editor, restore, sheet or alert on screen")
        XCTAssertEqual(review.considerRequest(ReviewMoment(appIsActive: false, scene: scene, homeIsIdle: true)), .noActiveScene)
        XCTAssertEqual(review.considerRequest(ReviewMoment(appIsActive: true, scene: nil, homeIsIdle: true)), .noActiveScene)
        XCTAssertEqual(requester.requests, 0)
        XCTAssertNil(history.lastRequestAttempt, "skipped checks don't start the cooldown")
        XCTAssertEqual(review.considerRequest(calm), .request)
    }

    // 8, 15
    func testNeverDuringOrRightAroundAFullscreenAd() async {
        let review = coordinator()
        makeEligible(review)
        gate.adWillPresent()
        XCTAssertEqual(review.considerRequest(calm), .adNearby)
        gate.adDidEnd(at: clock)
        clock += 30
        XCTAssertEqual(review.considerRequest(calm), .adNearby, "not right after an interstitial")
        clock += 31
        XCTAssertEqual(review.considerRequest(calm), .request)

        // And an automatic interstitial doesn't follow a review request right away; consent rules are untouched.
        let interstitial = FakeInterstitial()
        let entitlements = EntitlementService(store: MockStoreClient())
        await entitlements.refresh()
        let consent = FakeConsent()
        let ads = AdsCoordinator(entitlements: entitlements, consent: consent, sdk: FakeAdSDK(),
                                 configuration: AdConfiguration(appID: "ca-app-pub-1~1", bannerUnitID: "ca-app-pub-1/1", interstitialUnitID: "ca-app-pub-1/2"),
                                 interstitial: interstitial, history: MemoryInterstitialHistory(), gate: gate, now: { [unowned self] in self.clock })
        ads.developer = nil
        await ads.prepareIfNeeded(from: UIViewController())
        XCTAssertEqual(consent.gatherCount, 1, "UMP still runs first")
        XCTAssertEqual(ads.decorationSaved(presenter: UIViewController(), presenterIdle: true), .reviewNearby)
        XCTAssertEqual(interstitial.presentCount, 0)
        clock += 61
        XCTAssertEqual(ads.decorationSaved(presenter: UIViewController(), presenterIdle: true), .show)
    }

    // 10, 11
    func testSettingsLinkUsesTheRealIDOrExplains() {
        XCTAssertEqual(AppStoreReviewLink.url(appStoreID: "6712345678")?.absoluteString,
                       "https://apps.apple.com/app/id6712345678?action=write-review")
        for invalid in [nil, "", "  ", "$(APP_STORE_ID)", "FoodManager.HowCode", "123abc"] {
            XCTAssertNil(AppStoreReviewLink.url(appStoreID: invalid), "\(String(describing: invalid))")
        }
        XCTAssertNil(AppStoreReviewLink.configured, "no App Store ID until App Store Connect assigns one")

        let coordinator = NotificationCoordinator(client: FakeNotificationClient(), preferencesStore: InMemoryPreferencesStore(), snapshot: { nil })
        let settings = SettingsViewController(entitlements: nil, ads: nil, notifications: coordinator)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = UINavigationController(rootViewController: settings)
        window.makeKeyAndVisible()
        var opened: [URL] = []
        settings.openURL = { opened.append($0) }
        settings.reviewURL = AppStoreReviewLink.url(appStoreID: "6712345678")
        settings.openAppStoreReview()
        XCTAssertEqual(opened.map(\.absoluteString), ["https://apps.apple.com/app/id6712345678?action=write-review"])
        XCTAssertEqual(requester.requests, 0, "the button opens the App Store page, never the native prompt")
        settings.reviewURL = nil
        settings.openAppStoreReview()
        XCTAssertTrue(settings.presentedViewController is UIAlertController, "polite message when not available")
        XCTAssertEqual(opened.count, 1)
        window.isHidden = true
    }
}
