import UIKit
import XCTest
@testable import FoodManager

@MainActor
final class FakeInterstitial: InterstitialAdLoading {
    var isReady = false
    var isLoading = false
    var nextLoadSucceeds = true
    var autoDismiss = true
    var presentFails = false
    private(set) var loadCount = 0
    private(set) var presentCount = 0
    private var pendingDismiss: ((Bool) -> Void)?

    func load(unitID: String, completion: @escaping (Bool) -> Void) {
        loadCount += 1
        isReady = nextLoadSucceeds
        completion(nextLoadSucceeds)
    }

    func present(from viewController: UIViewController, onDismiss: @escaping (Bool) -> Void) -> Bool {
        guard isReady else { return false }
        presentCount += 1
        isReady = false
        if presentFails { onDismiss(false) } else if autoDismiss { onDismiss(true) } else { pendingDismiss = onDismiss }
        return true
    }

    func userClosesAd() {
        pendingDismiss?(true)
        pendingDismiss = nil
    }
}

final class MemoryInterstitialHistory: InterstitialHistoryStore {
    var lastAutomaticImpression: Date?
    var dailyCount: (day: String, count: Int)?
}

/// Phase 5A: interstitial placements, usage sessions, caps, consent and the manual 觀看廣告 action.
@MainActor
final class AdInterstitialTests: XCTestCase {
    private var clock = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private let presenter = UIViewController()
    private var interstitial: FakeInterstitial!
    private var history: MemoryInterstitialHistory!
    private var consent: FakeConsent!
    private var gate = FullscreenPresentationGate()

    private func makeCoordinator(session: AdUsageSession = AdUsageSession(),
                                 configuration: AdConfiguration = AdConfiguration(appID: "ca-app-pub-1~1", bannerUnitID: "ca-app-pub-1/1",
                                                                                  interstitialUnitID: "ca-app-pub-1/2")) async -> AdsCoordinator {
        let entitlements = EntitlementService(store: MockStoreClient())
        await entitlements.refresh()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Taipei")!
        let ads = AdsCoordinator(entitlements: entitlements, consent: consent, sdk: FakeAdSDK(), configuration: configuration,
                                 interstitial: interstitial, history: history, frequency: InterstitialFrequencyPolicy(calendar: calendar),
                                 session: session, gate: gate, now: { [unowned self] in self.clock })
        ads.developer = nil
        await ads.prepareIfNeeded(from: presenter)
        return ads
    }

    override func setUp() async throws {
        interstitial = FakeInterstitial()
        history = MemoryInterstitialHistory()
        consent = FakeConsent()
        gate = FullscreenPresentationGate()
    }

    private func leaveApp(for minutes: Double, _ ads: AdsCoordinator) {
        ads.appDidEnterBackground()
        clock += minutes * 60
        ads.appWillEnterForeground()
    }

    func testFirstSavedDecorationOfASessionShowsOneAd() async {
        let ads = await makeCoordinator()
        XCTAssertEqual(interstitial.loadCount, 1, "preloaded once the SDK is ready")
        XCTAssertEqual(ads.decorationSaved(presenter: presenter, presenterIdle: true), .show)
        XCTAssertEqual(interstitial.presentCount, 1)
        XCTAssertEqual(history.dailyCount?.count, 1)
        // Second save in the same session: nothing, and no pointless preload.
        clock += 20 * 60
        XCTAssertEqual(ads.decorationSaved(presenter: presenter, presenterIdle: true), .alreadyShownThisSession)
        XCTAssertEqual(interstitial.presentCount, 1)
        XCTAssertEqual(interstitial.loadCount, 1)
    }

    func testShortTripsToTheBackgroundKeepTheSession() async {
        let ads = await makeCoordinator()
        ads.decorationSaved(presenter: presenter, presenterIdle: true)
        leaveApp(for: 5, ads)
        leaveApp(for: 29, ads)
        interstitial.isReady = true
        XCTAssertEqual(ads.decorationSaved(presenter: presenter, presenterIdle: true), .alreadyShownThisSession)
        leaveApp(for: 30, ads) // ≥ 30 minutes away → a new usage session
        XCTAssertEqual(ads.decorationSaved(presenter: presenter, presenterIdle: true), .show)
        XCTAssertEqual(interstitial.presentCount, 2)
    }

    func testDailyCapAndCooldown() async {
        let ads = await makeCoordinator()
        ads.decorationSaved(presenter: presenter, presenterIdle: true)
        leaveApp(for: 40, ads)
        interstitial.isReady = true
        XCTAssertEqual(ads.decorationSaved(presenter: presenter, presenterIdle: true), .show)
        leaveApp(for: 40, ads)
        interstitial.isReady = true
        XCTAssertEqual(ads.decorationSaved(presenter: presenter, presenterIdle: true), .dailyCapReached, "max 2 per day")
        clock += 24 * 3600 // next day
        XCTAssertEqual(ads.decorationSaved(presenter: presenter, presenterIdle: true), .show)

        // A relaunch (new process → new session) within 10 minutes of the last automatic ad: cooldown.
        clock += 3 * 60
        let relaunched = await makeCoordinator()
        interstitial.isReady = true
        XCTAssertEqual(relaunched.decorationSaved(presenter: presenter, presenterIdle: true), .coolingDown)
        clock += 8 * 60
        XCTAssertEqual(relaunched.decorationSaved(presenter: presenter, presenterIdle: true), .show)
    }

    func testNeverWaitsForOrLatePresentsAnAd() async {
        interstitial.nextLoadSucceeds = false
        let ads = await makeCoordinator()
        XCTAssertEqual(ads.decorationSaved(presenter: presenter, presenterIdle: true), .notLoaded)
        XCTAssertEqual(interstitial.presentCount, 0)
        interstitial.nextLoadSucceeds = true
        ads.preloadAutomaticInterstitialIfUseful()
        XCTAssertTrue(interstitial.isReady)
        XCTAssertEqual(interstitial.presentCount, 0, "a late load is never shown by itself")
        XCTAssertEqual(ads.decorationSaved(presenter: presenter, presenterIdle: false), .userBusy, "not while the user is busy")
        XCTAssertEqual(interstitial.presentCount, 0)
    }

    func testConsentDeniedMeansNoRequests() async {
        consent.result = ConsentResult(canRequestAds: false, privacyOptionsRequired: true)
        let ads = await makeCoordinator()
        XCTAssertFalse(ads.eligibility.allowsAds)
        XCTAssertEqual(interstitial.loadCount, 0)
        XCTAssertEqual(ads.decorationSaved(presenter: presenter, presenterIdle: true), .adsNotAllowed)
        let manual = await ads.presentManualAd(from: presenter) { true }
        XCTAssertEqual(manual, .unavailable)
        XCTAssertEqual(interstitial.loadCount, 0)
    }

    func testMissingInterstitialUnitDisablesOnlyInterstitials() async {
        let ads = await makeCoordinator(configuration: AdConfiguration(appID: "ca-app-pub-1~1", bannerUnitID: "ca-app-pub-1/1"))
        XCTAssertTrue(ads.eligibility.allowsAds, "the banner still works")
        XCTAssertEqual(ads.decorationSaved(presenter: presenter, presenterIdle: true), .adsNotAllowed)
        XCTAssertEqual(interstitial.loadCount, 0)
        XCTAssertTrue(AdConfiguration(appID: "x", bannerUnitID: "y", interstitialUnitID: AdConfiguration.googleTestInterstitialUnitID)
            .usesGoogleTestIDs, "Release refuses Google's test interstitial too")
    }

    func testManualAdShowsLoadsOrExplains() async {
        let ads = await makeCoordinator()
        var outcome = await ads.presentManualAd(from: presenter) { true }
        XCTAssertEqual(outcome, .shown, "uses the preloaded ad")
        XCTAssertNil(history.dailyCount, "manual ads don't count toward the automatic cap")
        outcome = await ads.presentManualAd(from: presenter) { true }
        XCTAssertEqual(outcome, .shown, "loads one on demand")
        interstitial.nextLoadSucceeds = false
        outcome = await ads.presentManualAd(from: presenter) { true }
        XCTAssertEqual(outcome, .unavailable, "no fill / load failure → message, app continues")
        interstitial.nextLoadSucceeds = true
        outcome = await ads.presentManualAd(from: presenter) { false }
        XCTAssertEqual(outcome, .unavailable, "loaded after the user left the screen → not shown")
        XCTAssertEqual(interstitial.presentCount, 2)
        XCTAssertEqual(ads.decorationSaved(presenter: presenter, presenterIdle: true), .show, "the automatic placement is still available")
    }

    func testNeverTwoFullscreenAdsAtOnce() async {
        let ads = await makeCoordinator()
        interstitial.autoDismiss = false
        XCTAssertEqual(ads.decorationSaved(presenter: presenter, presenterIdle: true), .show)
        XCTAssertTrue(ads.isFullscreenAdActive)
        let manual = await ads.presentManualAd(from: presenter) { true }
        XCTAssertEqual(manual, .busy)
        interstitial.userClosesAd()
        XCTAssertFalse(ads.isFullscreenAdActive, "dismissal releases the lock; navigation stays where it was")
        // A failed presentation doesn't count as an impression.
        interstitial.presentFails = true
        interstitial.isReady = true
        let failed = await ads.presentManualAd(from: presenter) { true }
        XCTAssertEqual(failed, .unavailable)
        XCTAssertFalse(ads.isFullscreenAdActive)
    }

    func testPlacementsOnlyWhereAllowed() {
        for screen in AppScreen.allCases {
            XCTAssertEqual(AdPlacement.closedHomeBanner.isAllowed(on: screen), screen == .closedHome)
            XCTAssertEqual(AdPlacement.decorationSavedInterstitial.isAllowed(on: screen), screen == .closedHome)
            XCTAssertEqual(AdPlacement.manualInterstitial.isAllowed(on: screen), screen == .settings)
        }
        XCTAssertFalse(AdPlacement.allCases.contains { $0.isAllowed(on: .widget) }, "never in widgets")
        XCTAssertFalse(AdPlacement.allCases.contains { $0.isAllowed(on: .foodEditor) || $0.isAllowed(on: .layoutEditing) })
    }

    func testOnlyASuccessfulSaveReportsBack() throws {
        let container = try SwiftDataFridgeStore.makeContainer(inMemory: true)
        let fridge = try SwiftDataFridgeStore(container: container).loadAll()[0].fridge
        let store = FailingMagnetStore(base: SwiftDataMagnetStore(container: container))
        let library = MagnetLibrary(store: store, images: MagnetImageStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
        let editor = MagnetEditorViewController(fridge: fridge, library: library, magnets: [])
        var saved = 0
        editor.onSaved = { saved += 1 }
        editor.loadViewIfNeeded()
        store.failWrites = true
        editor.save()
        XCTAssertEqual(saved, 0, "a failed save never leads to an ad")
        editor.cancel()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(saved, 0, "cancel never leads to an ad")
    }
}
