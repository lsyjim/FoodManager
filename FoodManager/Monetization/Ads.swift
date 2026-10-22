import UIKit
import os

extension Notification.Name {
    /// Posted on the main thread when whether ads may be shown changes.
    static let adAvailabilityDidChange = Notification.Name("AdAvailabilityDidChange")
}

// MARK: - Configuration

/// AdMob identifiers come from Info.plist (set per build configuration in the project).
/// Debug uses Google's official test IDs; production IDs must be filled in before release.
struct AdConfiguration: Equatable {
    static let googleTestAppID = "ca-app-pub-3940256099942544~1458002511"
    static let googleTestBannerUnitID = "ca-app-pub-3940256099942544/2435281174"

    let appID: String
    let bannerUnitID: String

    var usesGoogleTestIDs: Bool { appID == Self.googleTestAppID || bannerUnitID == Self.googleTestBannerUnitID }
    var isComplete: Bool { appID.hasPrefix("ca-app-pub-") && bannerUnitID.hasPrefix("ca-app-pub-") }

    static func fromBundle(_ bundle: Bundle = .main) -> AdConfiguration {
        AdConfiguration(appID: bundle.object(forInfoDictionaryKey: "GADApplicationIdentifier") as? String ?? "",
                        bannerUnitID: bundle.object(forInfoDictionaryKey: "FMAdMobBannerUnitID") as? String ?? "")
    }
}

// MARK: - Placement rules

/// Screens of the app, for deciding where ads may appear.
enum AppScreen: CaseIterable {
    case closedHome, openFridge, layoutEditing, foodEditor, reminderCenter, foodHistory, search
    case settings, purchase, widget
}

/// The only ad placement in Phase 4.
enum AdPlacement: CaseIterable {
    case closedHomeBanner

    func isAllowed(on screen: AppScreen) -> Bool {
        switch self {
        case .closedHomeBanner: return screen == .closedHome
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

    func allows(_ placement: AdPlacement, on screen: AppScreen, contentHeightAfterBanner: CGFloat) -> Bool {
        allowsAds && placement.isAllowed(on: screen) && contentHeightAfterBanner >= Self.minimumContentHeight
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

    init(entitlements: EntitlementService, consent: AdConsentProviding, sdk: AdSDKStarting,
         configuration: AdConfiguration = .fromBundle()) {
        self.entitlements = entitlements
        self.consent = consent
        self.sdk = sdk
        self.configuration = configuration
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
    }

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
    var onLoaded: (() -> Void)? { get set }
    var onFailed: ((Error) -> Void)? { get set }
    /// The ad view to embed; nil before `load` is called.
    var view: UIView? { get }
    func load(width: CGFloat, rootViewController: UIViewController) -> CGSize
    func destroy()
}
