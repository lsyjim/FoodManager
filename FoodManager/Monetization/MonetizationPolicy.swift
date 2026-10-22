import Foundation

/// The one switch for paid features. While `isEnabled` is false (Phase 4.1: everything is free):
/// - no purchase screen, upgrade / restore rows, Premium labels or developer purchase switches are shown;
/// - the ad SDK is never started and no ad is requested;
/// - StoreKit code, product IDs, the `.storekit` file and the user's real transactions stay intact
///   (the entitlement service keeps running so purchases are finished and observed, never faked).
/// Turning it back on restores the Phase 4 behaviour without other code changes.
struct MonetizationPolicy: Equatable {
    var isEnabled: Bool

    static let current = MonetizationPolicy(isEnabled: false)
}

/// What the UI receives. Built in one place from the policy.
struct MonetizationServices {
    /// StoreKit observer; runs whenever the app uses persistent storage, regardless of the policy.
    let entitlementObserver: EntitlementService?
    /// Passed to screens only while monetization is enabled (nil hides every paid entry point).
    let entitlementsForUI: EntitlementService?
    /// nil while monetization is disabled → no ad SDK start, no requests, no banner view.
    let ads: AdsCoordinator?

    static let none = MonetizationServices(entitlementObserver: nil, entitlementsForUI: nil, ads: nil)

    @MainActor
    static func make(policy: MonetizationPolicy, mode: PersistenceMode,
                     store: @autoclosure () -> StoreClient = AppStoreClient(),
                     makeAds: @MainActor (EntitlementService) -> AdsCoordinator = { @MainActor in
                         AdsCoordinator(entitlements: $0, consent: GoogleConsentProvider(), sdk: GoogleAdSDK())
                     }) -> MonetizationServices {
        guard mode == .persistent else { return .none }
        let entitlements = EntitlementService(store: store())
        entitlements.start()
        guard policy.isEnabled else {
            return MonetizationServices(entitlementObserver: entitlements, entitlementsForUI: nil, ads: nil)
        }
        return MonetizationServices(entitlementObserver: entitlements, entitlementsForUI: entitlements, ads: makeAds(entitlements))
    }
}
