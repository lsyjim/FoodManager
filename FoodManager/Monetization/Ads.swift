import UIKit
import os

extension Notification.Name {
    /// Posted on the main thread when whether ads may be shown changes.
    static let adAvailabilityDidChange = Notification.Name("AdAvailabilityDidChange")
}

// MARK: - Configuration

/// AdMob identifiers come from Info.plist (set per build configuration in the project).
/// Debug uses Google's official test IDs; Release must carry the production IDs from the AdMob account
/// (an archive with test or missing IDs fails — see the "Check AdMob IDs" build phase).
struct AdConfiguration: Equatable {
    static let googleTestAppID = "ca-app-pub-3940256099942544~1458002511"
    static let googleTestBannerUnitID = "ca-app-pub-3940256099942544/2435281174"
    static let googleTestInterstitialUnitID = "ca-app-pub-3940256099942544/4411468910"

    let appID: String
    let bannerUnitID: String
    var interstitialUnitID: String = ""

    var usesGoogleTestIDs: Bool {
        appID == Self.googleTestAppID || bannerUnitID == Self.googleTestBannerUnitID
            || interstitialUnitID == Self.googleTestInterstitialUnitID
    }
    var isComplete: Bool { appID.hasPrefix("ca-app-pub-") && bannerUnitID.hasPrefix("ca-app-pub-") }
    var hasInterstitial: Bool { isComplete && interstitialUnitID.hasPrefix("ca-app-pub-") }

    static func fromBundle(_ bundle: Bundle = .main) -> AdConfiguration {
        AdConfiguration(appID: bundle.object(forInfoDictionaryKey: "GADApplicationIdentifier") as? String ?? "",
                        bannerUnitID: bundle.object(forInfoDictionaryKey: "FMAdMobBannerUnitID") as? String ?? "",
                        interstitialUnitID: bundle.object(forInfoDictionaryKey: "FMAdMobInterstitialUnitID") as? String ?? "")
    }
}

// MARK: - Placement rules

/// Screens of the app, for deciding where ads may appear.
enum AppScreen: CaseIterable {
    case closedHome, openFridge, layoutEditing, foodEditor, reminderCenter, foodHistory, search
    case settings, purchase, widget
}

/// Every ad placement in version 1.0. Nothing else may show an ad (food editing, layouts, widgets, launch…).
enum AdPlacement: CaseIterable {
    /// Adaptive banner under the closed fridge.
    case closedHomeBanner
    /// Interstitial on the closed fridge, right after the first saved decoration of a usage session.
    case decorationSavedInterstitial
    /// Interstitial the user asked for in 設定 → 觀看廣告.
    case manualInterstitial

    func isAllowed(on screen: AppScreen) -> Bool {
        switch self {
        case .closedHomeBanner, .decorationSavedInterstitial: return screen == .closedHome
        case .manualInterstitial: return screen == .settings
        }
    }
}

/// Pure rule set: every condition must hold before an ad is requested or shown.
struct AdEligibility: Equatable {
    var entitlement: EntitlementState
    var canRequestAds: Bool
    var sdkReady: Bool
    var developerAdsEnabled = true

    /// Whether ad requests are allowed at all (independent of screen).
    var allowsAds: Bool {
        entitlement == .free && canRequestAds && sdkReady && developerAdsEnabled
    }

    /// Smallest height the closed-home area needs for the fridge and dashboard to stay usable.
    static let minimumContentHeight: CGFloat = 380

    func allows(_ placement: AdPlacement, on screen: AppScreen, contentHeightAfterBanner: CGFloat,
                minimumContentHeight: CGFloat = minimumContentHeight) -> Bool {
        allowsAds && placement.isAllowed(on: screen)
            && contentHeightAfterBanner >= max(Self.minimumContentHeight, minimumContentHeight)
    }
}

// MARK: - SDK abstractions

/// Result of the consent flow.
struct ConsentResult: Equatable {
    /// UMP says ads (personalized or not, per the user's choice) may be requested.
    let canRequestAds: Bool
    let privacyOptionsRequired: Bool
}

@MainActor
protocol AdConsentProviding: AnyObject {
    /// Updates consent info and shows the consent form if UMP requires it.
    func gatherConsent(from viewController: UIViewController) async -> ConsentResult
    func presentPrivacyOptions(from viewController: UIViewController) async -> ConsentResult
    #if DEBUG
    func resetConsent()
    #endif
}

@MainActor
protocol AdSDKStarting: AnyObject {
    func start() async
}

// MARK: - Coordinator

/// Decides whether ads may run: free (verified by StoreKit) → consent → SDK start. Premium users never
/// start the ad SDK. No refrigerator or food code depends on this.
@MainActor
final class AdsCoordinator {
    private let entitlements: EntitlementService
    private let consent: AdConsentProviding
    private let sdk: AdSDKStarting
    let configuration: AdConfiguration
    private let logger = Logger(subsystem: "FoodManager.HowCode", category: "Ads")

    #if DEBUG
    /// Developer switches (nil in tests).
    var developer: DeveloperOverrides? = .shared
    #endif
    private(set) var canRequestAds = false
    private(set) var privacyOptionsRequired = false
    private(set) var sdkReady = false
    private var isPreparing = false

    // Interstitials
    private let interstitial: InterstitialAdLoading?
    private let history: InterstitialHistoryStore
    private let frequency: InterstitialFrequencyPolicy
    let session: AdUsageSession
    private let gate: FullscreenPresentationGate
    private let now: () -> Date
    /// A full-screen ad is on screen (from either placement). Never two at once.
    private(set) var isFullscreenAdActive = false
    /// Session number in which the automatic interstitial was shown.
    private var automaticShownInSession: Int?
    /// Last automatic decision, for diagnostics and tests.
    private(set) var lastAutomaticDecision: AutomaticInterstitialDecision?

    init(entitlements: EntitlementService, consent: AdConsentProviding, sdk: AdSDKStarting,
         configuration: AdConfiguration = .fromBundle(), interstitial: InterstitialAdLoading? = nil,
         history: InterstitialHistoryStore = UserDefaultsInterstitialHistory(),
         frequency: InterstitialFrequencyPolicy = InterstitialFrequencyPolicy(),
         session: AdUsageSession = AdUsageSession(), gate: FullscreenPresentationGate = .shared,
         now: @escaping () -> Date = Date.init) {
        self.gate = gate
        self.entitlements = entitlements
        self.consent = consent
        self.sdk = sdk
        self.configuration = configuration
        self.interstitial = interstitial
        self.history = history
        self.frequency = frequency
        self.session = session
        self.now = now
        NotificationCenter.default.addObserver(self, selector: #selector(entitlementsChanged),
                                               name: .entitlementsDidChange, object: nil)
        if configuration.usesGoogleTestIDs {
            logger.notice("AdMob is using Google's test IDs")
        }
    }

    var eligibility: AdEligibility {
        var eligibility = AdEligibility(entitlement: entitlements.state, canRequestAds: canRequestAds, sdkReady: sdkReady)
        #if DEBUG
        eligibility.developerAdsEnabled = developer?.adsEnabled ?? true
        #endif
        if !configuration.isComplete { eligibility.canRequestAds = false }
        #if !DEBUG
        // Release builds never serve Google's test ads: ads stay off until production IDs are configured.
        if configuration.usesGoogleTestIDs { eligibility.canRequestAds = false }
        #endif
        return eligibility
    }

    /// Runs consent and SDK start once the user is known to be free. Safe to call repeatedly.
    func prepareIfNeeded(from viewController: UIViewController) async {
        guard entitlements.state == .free, !isPreparing, configuration.isComplete else { return }
        #if !DEBUG
        guard !configuration.usesGoogleTestIDs else { return }
        #endif
        isPreparing = true
        defer { isPreparing = false }
        if !canRequestAds {
            let result = await consent.gatherConsent(from: viewController)
            canRequestAds = result.canRequestAds
            privacyOptionsRequired = result.privacyOptionsRequired
        }
        if canRequestAds && !sdkReady && entitlements.state == .free {
            await sdk.start()
            sdkReady = true
        }
        publish()
        preloadAutomaticInterstitialIfUseful()
    }

    // MARK: Interstitials

    private var interstitialAllowed: Bool { eligibility.allowsAds && configuration.hasInterstitial && interstitial != nil }

    private var automaticShownThisSession: Bool { automaticShownInSession == session.number }

    /// Loads an ad ahead of time only while an automatic interstitial could still be shown this session today.
    func preloadAutomaticInterstitialIfUseful() {
        guard interstitialAllowed, let interstitial, !interstitial.isReady, !interstitial.isLoading,
              !automaticShownThisSession else { return }
        if let daily = history.dailyCount, daily.day == frequency.dayKey(now()), daily.count >= InterstitialFrequencyPolicy.dailyCap { return }
        interstitial.load(unitID: configuration.interstitialUnitID) { _ in }
    }

    /// After a fridge decoration was saved and the closed fridge is showing again. Shows the interstitial only if
    /// it is already loaded and every rule allows it — never waits, never shows later on another screen.
    @discardableResult
    func decorationSaved(presenter: UIViewController, presenterIdle: Bool) -> AutomaticInterstitialDecision {
        let decision = frequency.decide(now: now(), adsAllowed: interstitialAllowed, shownThisSession: automaticShownThisSession,
                                        history: history, fullscreenActive: isFullscreenAdActive,
                                        loaded: interstitial?.isReady == true, presenterIdle: presenterIdle)
        lastAutomaticDecision = decision
        if decision == .show, !gate.canPresentAd(now: now()) {
            lastAutomaticDecision = .reviewNearby
            return .reviewNearby
        }
        guard decision == .show, let interstitial else {
            if decision == .notLoaded { preloadAutomaticInterstitialIfUseful() }
            return decision
        }
        isFullscreenAdActive = true
        gate.adWillPresent()
        let presented = interstitial.present(from: presenter) { [weak self] shown in
            guard let self else { return }
            self.isFullscreenAdActive = false
            self.gate.adDidEnd(at: self.now())
            if shown {
                self.automaticShownInSession = self.session.number
                self.frequency.recordAutomaticImpression(at: self.now(), in: self.history)
            }
        }
        if !presented {
            isFullscreenAdActive = false
            gate.adDidEnd(at: now())
        }
        return presented ? .show : .notLoaded
    }

    /// 設定 → 觀看廣告: an ordinary interstitial the user explicitly asked for (no reward). If none is loaded, one
    /// load is attempted; it is shown only if `stillVisible()` says the user is still on that screen.
    func presentManualAd(from presenter: UIViewController, stillVisible: @escaping () -> Bool) async -> ManualAdOutcome {
        guard !isFullscreenAdActive else { return .busy }
        guard interstitialAllowed, let interstitial else { return .unavailable }
        if !interstitial.isReady {
            let loaded: Bool = await withCheckedContinuation { continuation in
                if interstitial.isLoading {
                    // Another load is running; give it a moment instead of starting a second one.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 4) { continuation.resume(returning: interstitial.isReady) }
                } else {
                    interstitial.load(unitID: configuration.interstitialUnitID) { continuation.resume(returning: $0) }
                }
            }
            guard loaded, stillVisible() else { return .unavailable }
        }
        guard !isFullscreenAdActive else { return .busy }
        isFullscreenAdActive = true
        gate.adWillPresent()
        return await withCheckedContinuation { continuation in
            let presented = interstitial.present(from: presenter) { [weak self] shown in
                guard let self else { return continuation.resume(returning: .unavailable) }
                self.isFullscreenAdActive = false
                self.gate.adDidEnd(at: self.now())
                continuation.resume(returning: shown ? .shown : .unavailable)
            }
            if !presented {
                isFullscreenAdActive = false
                gate.adDidEnd(at: now())
                continuation.resume(returning: .unavailable)
            }
        }
    }

    func appDidEnterBackground() { session.didEnterBackground(at: now()) }
    func appWillEnterForeground() { session.willEnterForeground(at: now()) }

    func presentPrivacyOptions(from viewController: UIViewController) async {
        let result = await consent.presentPrivacyOptions(from: viewController)
        canRequestAds = result.canRequestAds
        privacyOptionsRequired = result.privacyOptionsRequired
        publish()
    }

    #if DEBUG
    func resetConsentForTesting() {
        consent.resetConsent()
        canRequestAds = false
        privacyOptionsRequired = false
        publish()
    }

    func developerSettingsChanged() { publish() }
    #endif

    @objc private func entitlementsChanged() { publish() }

    private func publish() {
        NotificationCenter.default.post(name: .adAvailabilityDidChange, object: self)
    }
}

// MARK: - Banner loading

/// Creates and loads one banner view. The live implementation wraps Google's `BannerView`.
@MainActor
protocol BannerAdLoading: AnyObject {
    /// Use the regular anchored adaptive size (≈50pt) instead of the large one, for short screens.
    var prefersCompact: Bool { get set }
    var onLoaded: (() -> Void)? { get set }
    var onFailed: ((Error) -> Void)? { get set }
    /// The ad view to embed; nil before `load` is called.
    var view: UIView? { get }
    func load(width: CGFloat, rootViewController: UIViewController) -> CGSize
    func destroy()
}
