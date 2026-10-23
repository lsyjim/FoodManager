import Foundation

/// The business model of this build, in one place. Version 1.0: free app with ads; nothing can be bought.
///
/// - `adsEnabled`: the home-screen banner and the two interstitial placements (after the first saved fridge
///   decoration of a session, and 設定 → 觀看廣告). Ads run only after Google UMP consent allows requests, and
///   Release builds never request Google's test ads.
/// - `purchasesEnabled`: false → no purchase screen, upgrade / restore rows, Premium labels or paywalls. StoreKit
///   code, product IDs and the `.storekit` file stay in the project, and the entitlement observer keeps running so
///   any genuine earlier (sandbox / TestFlight) purchase is reported truthfully — it is never faked.
///
/// These are compile-time constants reviewed with each release, not a remote or hidden switch: changing the
/// business model requires a new build and App Review.
struct MonetizationPolicy: Equatable {
    var adsEnabled: Bool
    var purchasesEnabled: Bool

    static let current = MonetizationPolicy(adsEnabled: true, purchasesEnabled: false)
}

/// What the UI receives. Built in one place from the policy.
struct MonetizationServices {
    /// StoreKit observer; runs whenever the app uses persistent storage, regardless of the policy.
    let entitlementObserver: EntitlementService?
    /// Passed to screens only while purchases are enabled (nil hides every paid entry point).
    let entitlementsForUI: EntitlementService?
    /// nil while ads are disabled → no ad SDK start, no requests, no banner view, no interstitials.
    let ads: AdsCoordinator?

    static let none = MonetizationServices(entitlementObserver: nil, entitlementsForUI: nil, ads: nil)

    @MainActor
    static func make(policy: MonetizationPolicy, mode: PersistenceMode,
                     store: @autoclosure () -> StoreClient = AppStoreClient(),
                     makeAds: @MainActor (EntitlementService) -> AdsCoordinator = { @MainActor in
                         AdsCoordinator(entitlements: $0, consent: GoogleConsentProvider(), sdk: GoogleAdSDK(),
                                        interstitial: GoogleInterstitialLoader())
                     }) -> MonetizationServices {
        guard mode == .persistent else { return .none }
        let entitlements = EntitlementService(store: store())
        entitlements.start()
        return MonetizationServices(entitlementObserver: entitlements,
                                    entitlementsForUI: policy.purchasesEnabled ? entitlements : nil,
                                    ads: policy.adsEnabled ? makeAds(entitlements) : nil)
    }
}
