import Foundation

/// Shared refrigerators (Phase 5D), in one place next to `MonetizationPolicy`.
///
/// - `sharedRefrigeratorsEnabled`: master switch. Off → no entry points, incoming share links are ignored (never
///   accepted, no paywall) and the shared-fridge sync engine never starts.
/// - `sharedRefrigeratorsRequirePremium`: only the owner who *starts* sharing needs Premium; members never do.
/// - `accessRequestsSupported`: the approval workflow (request → owner approves) needs iOS 26 CloudKit APIs. The
///   design never falls back to a public link, so older systems get no sharing at all.
///
/// Compile-time constants reviewed with each release: Debug builds enable sharing for development, Release 1.0
/// keeps it off. Nothing here grants Premium; `hasPremium` always comes from the real entitlement service.
struct SharingPolicy: Equatable {
    var sharedRefrigeratorsEnabled: Bool
    var sharedRefrigeratorsRequirePremium: Bool
    var accessRequestsSupported: Bool

    static var current: SharingPolicy {
        #if DEBUG
        SharingPolicy(sharedRefrigeratorsEnabled: true, sharedRefrigeratorsRequirePremium: false,
                      accessRequestsSupported: osSupportsAccessRequests)
        #else
        SharingPolicy(sharedRefrigeratorsEnabled: false, sharedRefrigeratorsRequirePremium: false,
                      accessRequestsSupported: osSupportsAccessRequests)
        #endif
    }

    static var osSupportsAccessRequests: Bool {
        if #available(iOS 26.0, *) { return true }
        return false
    }

    /// Entry points, incoming links and the sync engine all check this one value.
    var isActive: Bool { sharedRefrigeratorsEnabled && accessRequestsSupported }

    /// Whether this user may turn one of their fridges into a shared one.
    func startSharingGate(hasPremium: Bool) -> SharingGate {
        guard sharedRefrigeratorsEnabled else { return .disabled }
        guard accessRequestsSupported else { return .unsupportedSystem }
        if sharedRefrigeratorsRequirePremium && !hasPremium { return .requiresPremium }
        return .allowed
    }

    /// Whether an incoming share link may be opened. Members never need Premium.
    var joinGate: SharingGate {
        guard sharedRefrigeratorsEnabled else { return .disabled }
        guard accessRequestsSupported else { return .unsupportedSystem }
        return .allowed
    }
}

enum SharingGate: Equatable {
    case allowed
    /// Feature off in this build: show nothing (no paywall, no hint).
    case disabled
    case unsupportedSystem
    case requiresPremium
}

/// Where a refrigerator stands, as shown in the fridge selector.
enum SharedFridgeOwnership: Equatable {
    /// A normal fridge (SwiftData, or a formerly shared one whose sharing was stopped).
    case personalOwned
    case sharedOwned
    case sharedParticipant
    /// Access requested; no inventory data is readable until the owner approves.
    case pendingInvitation
    /// Removed, sharing stopped by the owner, or the zone is gone.
    case unavailableOrRevoked

    var selectorLabel: String? {
        switch self {
        case .personalOwned: return nil
        case .sharedOwned: return "已共享 · 我是主人"
        case .sharedParticipant: return "參與共享"
        case .pendingInvitation: return "等待主人同意"
        case .unavailableOrRevoked: return "共享無法存取"
        }
    }

    /// Counts toward `FridgePolicy.maxRefrigerators`. A pending request counts too, so approval can never push the
    /// user over the limit; an unavailable fridge holds no data and doesn't.
    var countsTowardLimit: Bool { self != .unavailableOrRevoked }
}

extension FridgePolicy {
    /// Owned + shared + joined (+ pending) refrigerators.
    static func fridgeCount(personal: Int, shared: [SharedFridgeOwnership]) -> Int {
        personal + shared.filter(\.countsTowardLimit).count
    }

    static func canAddFridge(personal: Int, shared: [SharedFridgeOwnership]) -> Bool {
        fridgeCount(personal: personal, shared: shared) < maxRefrigerators
    }
}
