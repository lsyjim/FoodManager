import StoreKitTest
import UIKit
import XCTest
@testable import FoodManager

// MARK: - Test doubles

final class MockStoreClient: StoreClient {
    struct Offline: Error {}
    var entitlements: [StoreTransactionInfo] = []
    var purchaseOutcome: StorePurchaseOutcome = .userCancelled
    var purchaseError: Error?
    var syncError: Error?
    var entitlementsAfterSync: [StoreTransactionInfo]?
    var productInfo: StoreProductInfo? = StoreProductInfo(id: StoreProducts.premium, displayName: "完整版", displayPrice: "NT$90")
    private(set) var updateHandler: (@Sendable () async -> Void)?

    func product(id: String) async throws -> StoreProductInfo? {
        if purchaseError != nil { throw Offline() }
        return productInfo
    }
    func purchase(productID: String) async throws -> StorePurchaseOutcome {
        if let purchaseError { throw purchaseError }
        if case let .purchased(info) = purchaseOutcome, info.grantsAccess { entitlements = [info] }
        return purchaseOutcome
    }
    func currentEntitlements() async -> [StoreTransactionInfo] { entitlements }
    func sync() async throws {
        if let syncError { throw syncError }
        if let after = entitlementsAfterSync { entitlements = after }
    }
    func observeTransactionUpdates(_ handler: @escaping @Sendable () async -> Void) -> Task<Void, Never> {
        updateHandler = handler
        return Task {}
    }
    /// Simulates StoreKit delivering a transaction update (approval, refund, other device).
    func deliverUpdate() async { await updateHandler?() }
}

@MainActor
final class FakeConsent: AdConsentProviding {
    var result = ConsentResult(canRequestAds: true, privacyOptionsRequired: false)
    private(set) var gatherCount = 0
    func gatherConsent(from viewController: UIViewController) async -> ConsentResult {
        gatherCount += 1
        return result
    }
    func presentPrivacyOptions(from viewController: UIViewController) async -> ConsentResult { result }
    func resetConsent() {}
}

@MainActor
final class FakeAdSDK: AdSDKStarting {
    private(set) var startCount = 0
    func start() async { startCount += 1 }
}

@MainActor
final class FakeBannerLoader: BannerAdLoading {
    var prefersCompact = false
    var onLoaded: (() -> Void)?
    var onFailed: ((Error) -> Void)?
    private(set) var view: UIView?
    private(set) var loadCount = 0
    private(set) var destroyed = false

    func load(width: CGFloat, rootViewController: UIViewController) -> CGSize {
        loadCount += 1
        if view == nil { view = UIView() }
        return CGSize(width: width, height: prefersCompact ? 50 : 60)
    }
    func destroy() {
        destroyed = true
        view?.removeFromSuperview()
        view = nil
    }
}

private let verifiedPremium = StoreTransactionInfo(productID: StoreProducts.premium, isVerified: true, revocationDate: nil)
private let testConfig = AdConfiguration(appID: AdConfiguration.googleTestAppID, bannerUnitID: AdConfiguration.googleTestBannerUnitID)

// MARK: - Entitlements

@MainActor
final class EntitlementTests: XCTestCase {
    private var store: MockStoreClient!
    private var service: EntitlementService!

    override func setUp() {
        super.setUp()
        store = MockStoreClient()
        service = EntitlementService(store: store, developer: nil)
    }

    // 1, 2
    func testFreeAndPremiumStatesComeFromVerifiedEntitlements() async {
        XCTAssertEqual(service.state, .unknown, "unknown until StoreKit answers")
        await service.refresh()
        XCTAssertEqual(service.state, .free)
        XCTAssertFalse(service.isEnabled(.removeAds))
        store.entitlements = [verifiedPremium]
        await service.refresh()
        XCTAssertEqual(service.state, .premium)
        XCTAssertTrue(service.isEnabled(.removeAds))
        XCTAssertFalse(service.isEnabled(.multipleRefrigerators), "future features stay inactive until implemented")
        XCTAssertFalse(service.isEnabled(.advancedFridgeTemplates))
    }

    // 3
    func testVerifiedPurchaseGrantsPremiumAndNotifies() async {
        await service.refresh()
        store.purchaseOutcome = .purchased(verifiedPremium)
        let changed = expectation(forNotification: .entitlementsDidChange, object: service)
        let result = await service.purchase()
        XCTAssertEqual(result, .purchased)
        XCTAssertTrue(service.isPremium)
        await fulfillment(of: [changed], timeout: 1)
    }

    // 4
    func testUnverifiedTransactionsNeverGrantPremium() async {
        await service.refresh()
        store.purchaseOutcome = .unverified
        guard case .failed = await service.purchase() else { return XCTFail() }
        XCTAssertFalse(service.isPremium)
        store.purchaseOutcome = .purchased(StoreTransactionInfo(productID: StoreProducts.premium, isVerified: false, revocationDate: nil))
        guard case .failed = await service.purchase() else { return XCTFail() }
        store.entitlements = [StoreTransactionInfo(productID: StoreProducts.premium, isVerified: false, revocationDate: nil)]
        await service.refresh()
        XCTAssertEqual(service.state, .free)
    }

    // 5
    func testCancelledPurchaseChangesNothing() async {
        await service.refresh()
        store.purchaseOutcome = .userCancelled
        let result = await service.purchase()
        XCTAssertEqual(result, .cancelled)
        XCTAssertEqual(service.state, .free)
    }

    // 6
    func testPendingPurchaseUnlocksOnlyAfterApprovalUpdate() async {
        service.start()
        await service.refresh()
        store.purchaseOutcome = .pending
        let result = await service.purchase()
        XCTAssertEqual(result, .pending)
        XCTAssertFalse(service.isPremium)
        store.entitlements = [verifiedPremium] // Ask to Buy approved
        await store.deliverUpdate()
        XCTAssertTrue(service.isPremium)
    }

    func testPurchaseFailureIsReported() async {
        await service.refresh()
        store.purchaseError = MockStoreClient.Offline()
        guard case .failed = await service.purchase() else { return XCTFail() }
        XCTAssertFalse(service.isPremium)
    }

    // 7
    func testRestoreOnlySucceedsWithVerifiedEntitlement() async {
        await service.refresh()
        let nothing = await service.restore()
        XCTAssertEqual(nothing, .nothingToRestore, "starting a restore never grants Premium by itself")
        XCTAssertFalse(service.isPremium)

        store.syncError = MockStoreClient.Offline()
        guard case .failed = await service.restore() else { return XCTFail() }
        XCTAssertFalse(service.isPremium)

        store.syncError = nil
        store.entitlementsAfterSync = [verifiedPremium]
        let restored = await service.restore()
        XCTAssertEqual(restored, .restored)
        XCTAssertTrue(service.isPremium)
    }

    // 8
    func testRevokedOrRefundedPurchaseRemovesPremium() async {
        service.start()
        store.entitlements = [verifiedPremium]
        await service.refresh()
        XCTAssertTrue(service.isPremium)
        store.entitlements = [StoreTransactionInfo(productID: StoreProducts.premium, isVerified: true, revocationDate: Date())]
        await store.deliverUpdate()
        XCTAssertEqual(service.state, .free)
        store.entitlements = []
        await service.refresh()
        XCTAssertEqual(service.state, .free)
    }

    // 9
    func testPurchaseStatePersistsThroughStoreKitNotLocalFlags() async {
        store.entitlements = [verifiedPremium] // StoreKit keeps this across launches (local receipt, offline too)
        let relaunched = EntitlementService(store: store, developer: nil)
        await relaunched.refresh()
        XCTAssertTrue(relaunched.isPremium)
        let wiped = EntitlementService(store: MockStoreClient(), developer: nil)
        UserDefaults.standard.set(true, forKey: "isPremium") // a stray flag must never count as proof
        defer { UserDefaults.standard.removeObject(forKey: "isPremium") }
        await wiped.refresh()
        XCTAssertFalse(wiped.isPremium)
    }

    func testDeveloperOverridesOnlyAffectDebugEffectiveState() async {
        let suite = "EntitlementTests.\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let developer = DeveloperOverrides(defaults: UserDefaults(suiteName: suite)!)
        let debugService = EntitlementService(store: store, developer: developer)
        await debugService.refresh()
        XCTAssertEqual(debugService.state, .free)
        developer.premium = .forcePremium
        XCTAssertTrue(debugService.isEnabled(.removeAds))
        XCTAssertEqual(debugService.purchasedState, .free, "the real StoreKit state is untouched")
        developer.premium = .forceFree
        store.entitlements = [verifiedPremium]
        await debugService.refresh()
        XCTAssertEqual(debugService.state, .free)
        developer.premium = .none
        XCTAssertEqual(debugService.state, .premium)
    }
}

// MARK: - Ads

@MainActor
final class AdTests: XCTestCase {
    private var store: MockStoreClient!
    private var entitlements: EntitlementService!
    private var consent: FakeConsent!
    private var sdk: FakeAdSDK!
    private var ads: AdsCoordinator!
    private let host = UIViewController()

    override func setUp() async throws {
        store = MockStoreClient()
        entitlements = EntitlementService(store: store, developer: nil)
        consent = FakeConsent()
        sdk = FakeAdSDK()
        ads = AdsCoordinator(entitlements: entitlements, consent: consent, sdk: sdk, configuration: testConfig)
        ads.developer = nil
    }

    // 10
    func testEligibilityRequiresEveryCondition() {
        let ok = AdEligibility(entitlement: .free, canRequestAds: true, sdkReady: true)
        XCTAssertTrue(ok.allows(.closedHomeBanner, on: .closedHome, contentHeightAfterBanner: 500))
        for broken in [AdEligibility(entitlement: .unknown, canRequestAds: true, sdkReady: true),
                       AdEligibility(entitlement: .premium, canRequestAds: true, sdkReady: true),
                       AdEligibility(entitlement: .free, canRequestAds: false, sdkReady: true),
                       AdEligibility(entitlement: .free, canRequestAds: true, sdkReady: false),
                       AdEligibility(entitlement: .free, canRequestAds: true, sdkReady: true, developerAdsEnabled: false)] {
            XCTAssertFalse(broken.allows(.closedHomeBanner, on: .closedHome, contentHeightAfterBanner: 500), "\(broken)")
        }
        XCTAssertFalse(ok.allows(.closedHomeBanner, on: .closedHome, contentHeightAfterBanner: 300), "no room → no ad")
    }

    // 16, 17, 18 (rules)
    func testBannerPlacementIsOnlyTheClosedHome() {
        for screen in AppScreen.allCases {
            XCTAssertEqual(AdPlacement.closedHomeBanner.isAllowed(on: screen), screen == .closedHome, "\(screen)")
        }
        XCTAssertEqual(AdPlacement.allCases, [.closedHomeBanner, .decorationSavedInterstitial, .manualInterstitial],
                       "version 1.0: one banner and two interstitials, no rewarded ads")
    }

    // 11
    func testPremiumNeverStartsConsentOrSDK() async {
        store.entitlements = [verifiedPremium]
        await entitlements.refresh()
        await ads.prepareIfNeeded(from: host)
        XCTAssertEqual(consent.gatherCount, 0)
        XCTAssertEqual(sdk.startCount, 0)
        XCTAssertFalse(ads.eligibility.allowsAds)
    }

    func testUnknownEntitlementWaits() async {
        await ads.prepareIfNeeded(from: host)
        XCTAssertEqual(sdk.startCount, 0, "no ads before StoreKit confirms the user is free")
    }

    func testFreeUserWithConsentStartsSDKOnce() async {
        await entitlements.refresh()
        await ads.prepareIfNeeded(from: host)
        await ads.prepareIfNeeded(from: host)
        XCTAssertEqual(sdk.startCount, 1)
        XCTAssertEqual(consent.gatherCount, 1)
        XCTAssertTrue(ads.eligibility.allowsAds)
    }

    // 14, 15
    func testConsentUnavailableOrDeniedMeansNoAds() async {
        await entitlements.refresh()
        consent.result = ConsentResult(canRequestAds: false, privacyOptionsRequired: true) // offline w/o prior consent, or denied
        await ads.prepareIfNeeded(from: host)
        XCTAssertEqual(sdk.startCount, 0)
        XCTAssertFalse(ads.eligibility.allowsAds)
        XCTAssertTrue(ads.privacyOptionsRequired, "settings offers 廣告與隱私設定")
    }

    func testIncompleteConfigurationDisablesAds() async {
        let empty = AdsCoordinator(entitlements: entitlements, consent: consent, sdk: sdk,
                                   configuration: AdConfiguration(appID: "", bannerUnitID: ""))
        empty.developer = nil
        await entitlements.refresh()
        await empty.prepareIfNeeded(from: host)
        XCTAssertEqual(sdk.startCount, 0)
        XCTAssertFalse(empty.eligibility.allowsAds)
    }

    func testBundledConfigurationUsesGoogleTestIDsInDebug() {
        let bundled = AdConfiguration.fromBundle()
        XCTAssertTrue(bundled.isComplete)
        XCTAssertTrue(bundled.usesGoogleTestIDs, "Debug builds must use Google's test IDs")
    }

    // 13
    func testLoadFailureCollapsesAndBacksOff() {
        let loader = FakeBannerLoader()
        let container = BannerAdContainerView(makeLoader: { loader })
        var scheduled: [TimeInterval] = []
        var pending: [@MainActor () -> Void] = []
        container.scheduleRetry = { delay, work in scheduled.append(delay); pending.append(work) }
        container.activate(width: 360, rootViewController: host)
        XCTAssertTrue(container.isHidden, "nothing shown before an ad loads")
        XCTAssertEqual(container.loadedHeight, 0)

        loader.onFailed?(NSError(domain: "ads", code: 1))
        XCTAssertTrue(container.isHidden, "collapsed after failure — no blank ad-sized gap")
        XCTAssertEqual(loader.loadCount, 1, "no immediate retry")
        pending.removeFirst()()
        loader.onFailed?(NSError(domain: "ads", code: 1))
        XCTAssertEqual(scheduled, [30, 60], "exponential back-off")

        pending.removeFirst()()
        loader.onLoaded?()
        XCTAssertFalse(container.isHidden)
        XCTAssertEqual(container.loadedHeight, 60)

        container.deactivate()
        XCTAssertTrue(loader.destroyed)
        XCTAssertTrue(container.isHidden)
    }
}

// MARK: - Home integration

@MainActor
final class HomeAdIntegrationTests: XCTestCase {
    private var window: UIWindow!
    private var home: FridgeHomeViewController!
    private var store: MockStoreClient!
    private var entitlements: EntitlementService!
    private var ads: AdsCoordinator!
    private var loaders: [FakeBannerLoader] = []

    override func setUp() async throws {
        guard case let .success(session) = AppBootstrap.start(.inMemoryForTesting()) else { return XCTFail() }
        store = MockStoreClient()
        entitlements = EntitlementService(store: store, developer: nil)
        ads = AdsCoordinator(entitlements: entitlements, consent: FakeConsent(), sdk: FakeAdSDK(), configuration: testConfig)
        ads.developer = nil
        home = FridgeHomeViewController(session: session, notificationClient: FakeNotificationClient(),
                                        widgetPublisher: WidgetSnapshotPublisher(file: nil, reloader: CountingReloader()),
                                        entitlements: entitlements, ads: ads,
                                        makeBannerLoader: { [unowned self] in
                                            let loader = FakeBannerLoader()
                                            self.loaders.append(loader)
                                            return loader
                                        })
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = UINavigationController(rootViewController: home)
        window.makeKeyAndVisible()
        home.loadViewIfNeeded()
        await settle()
    }

    override func tearDown() {
        window.rootViewController?.dismiss(animated: false)
        window = nil
        super.tearDown()
    }

    private func settle(_ seconds: Double = 0.2) async {
        window.layoutIfNeeded()
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        window.layoutIfNeeded()
    }

    private func becomeFreeWithAd() async {
        await entitlements.refresh()
        await ads.prepareIfNeeded(from: home)
        await settle()
        loaders.last?.onLoaded?()
        await settle()
    }

    // 12
    func testBannerShowsForFreeUserAndIsRemovedRightAfterPurchase() async throws {
        XCTAssertEqual(home.currentScreen, .closedHome)
        await becomeFreeWithAd()
        XCTAssertTrue(home.isShowingBanner)
        let loader = try XCTUnwrap(loaders.last)

        store.purchaseOutcome = .purchased(verifiedPremium)
        _ = await entitlements.purchase()
        await settle()
        XCTAssertFalse(home.isShowingBanner)
        XCTAssertTrue(loader.destroyed, "ad view released, no more requests")
    }

    func testNoBannerOnOpenFridgeOrInFoodEditor() async throws {
        await becomeFreeWithAd()
        XCTAssertTrue(home.isShowingBanner)
        home.handle(.link(AppDeepLink(.quickAdd(compartmentID: nil))))
        await settle()
        let editor = try XCTUnwrap((home.navigationController?.presentedViewController as? UINavigationController)?.topViewController)
        XCTAssertFalse(editor.view.allSubviews.contains { $0 is BannerAdContainerView }, "no ads in food editing")
        editor.dismiss(animated: false)
        await settle()

        // Open the door: the closed-home banner goes away.
        home.view.allSubviews.compactMap { $0 as? ClosedFridgeButton }.first?.sendActions(for: .touchUpInside)
        await settle(0.8)
        XCTAssertEqual(home.currentScreen, .openFridge)
        XCTAssertFalse(home.isShowingBanner)
    }

    // 19
    func testInventoryWorksOfflineWithStoreKitUnavailable() async throws {
        store.purchaseError = MockStoreClient.Offline()
        store.syncError = MockStoreClient.Offline()
        await entitlements.refresh()
        _ = await entitlements.restore()
        guard case let .success(session) = AppBootstrap.start(.inMemoryForTesting()) else { return XCTFail() }
        let fridge = session.loadResult.fridge
        let inventory = FoodInventoryService(store: session.foodStore, fridgeID: fridge.id, compartments: { fridge.allCompartments })
        var draft = FoodDraft(compartmentID: fridge.cabinetCompartments[0].id)
        draft.name = "離線牛奶"
        let milk = try inventory.add(draft)
        try inventory.markConsumed(milk.id)
        try inventory.restore(milk.id)
        XCTAssertEqual(inventory.items.map(\.name), ["離線牛奶"])
    }
}

// MARK: - Widget has no ads

final class WidgetAdIsolationTests: XCTestCase {
    // 18
    func testWidgetExtensionDoesNotContainTheAdSDK() throws {
        let appex = try XCTUnwrap(Bundle.main.builtInPlugInsURL?.appendingPathComponent("FoodManagerWidgets.appex"))
        let binary = appex.appendingPathComponent("FoodManagerWidgets")
        let data = try Data(contentsOf: binary)
        for marker in ["GADBannerView", "GoogleMobileAds", "UserMessagingPlatform"] {
            XCTAssertNil(data.range(of: Data(marker.utf8)), "widget binary references \(marker)")
        }
        let frameworks = (try? FileManager.default.contentsOfDirectory(atPath: appex.appendingPathComponent("Frameworks").path)) ?? []
        XCTAssertTrue(frameworks.isEmpty)
    }
}

// MARK: - Real StoreKit 2 against the local StoreKit configuration

@MainActor
final class StoreKitConfigurationTests: XCTestCase {
    private var session: SKTestSession!
    private let client = AppStoreClient()

    override func setUpWithError() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Config/FoodManager.storekit")
        session = try SKTestSession(contentsOf: url)
        session.resetToDefaultState()
        session.disableDialogs = true
        session.clearTransactions()
    }

    override func tearDown() {
        session.clearTransactions()
        super.tearDown()
    }

    /// Polls until `condition` holds (StoreKit delivers test-session changes asynchronously).
    private func eventually(_ timeout: TimeInterval = 5, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return await condition()
    }

    // 20
    func testProductLoadsWithLocalizedPrice() async throws {
        let product = try await client.product(id: StoreProducts.premium)
        XCTAssertEqual(product?.id, StoreProducts.premium)
        XCTAssertEqual(product?.displayName, "冰箱管理員完整版")
        XCTAssertFalse(product?.displayPrice.isEmpty ?? true, "price comes from StoreKit")
    }

    func testRealPurchaseRestoreAndRefund() async throws {
        let service = EntitlementService(store: client, developer: nil)
        await service.refresh()
        XCTAssertEqual(service.state, .free)
        _ = try await service.loadProduct()

        let result = await service.purchase()
        XCTAssertEqual(result, .purchased)
        XCTAssertTrue(service.isPremium)

        let relaunched = EntitlementService(store: client, developer: nil)
        await relaunched.refresh()
        XCTAssertTrue(relaunched.isPremium, "verified entitlement survives a relaunch")

        let transaction = try XCTUnwrap(session.allTransactions().first)
        try session.refundTransaction(identifier: transaction.identifier)
        let revoked = await eventually { await relaunched.refresh(); return relaunched.state == .free }
        XCTAssertTrue(revoked, "refunded purchase no longer grants Premium")
    }

    func testAskToBuyIsPendingUntilApproved() async throws {
        session.askToBuyEnabled = true
        let service = EntitlementService(store: client, developer: nil)
        service.start() // the approval arrives through Transaction.updates, as in the app
        await service.refresh()
        let result = await service.purchase()
        XCTAssertEqual(result, .pending)
        XCTAssertFalse(service.isPremium)
        let transaction = try XCTUnwrap(session.allTransactions().first)
        try session.approveAskToBuyTransaction(identifier: transaction.identifier)
        let unlocked = await eventually { service.isPremium }
        XCTAssertTrue(unlocked, "approval unlocks Premium via the update listener")
    }
}
