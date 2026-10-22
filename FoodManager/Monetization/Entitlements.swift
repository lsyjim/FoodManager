import Foundation
import os

extension Notification.Name {
    /// Posted on the main thread whenever the effective entitlement state changes.
    static let entitlementsDidChange = Notification.Name("EntitlementsDidChange")
}

/// Features a Premium purchase can unlock. Only features that exist in the app may be active;
/// the others are defined now so future work doesn't need to rethink the architecture.
enum PremiumFeature: CaseIterable {
    case removeAds
    case multipleRefrigerators
    case advancedFridgeTemplates

    /// Whether the feature is implemented in this build. Inactive features never unlock anything.
    var isImplemented: Bool {
        switch self {
        case .removeAds: return true
        case .multipleRefrigerators, .advancedFridgeTemplates: return false
        }
    }
}

enum EntitlementState: Equatable {
    /// Not determined yet (before the first StoreKit check). Ads stay off so Premium users never see a flash of ads.
    case unknown
    case free
    case premium
}

// MARK: - StoreKit abstraction

enum StoreProducts {
    /// Proposed product ID; must match App Store Connect before release.
    static let premium = "FoodManager.HowCode.premium"
}

/// What the app needs to know about a product (price always comes from StoreKit, never hardcoded).
struct StoreProductInfo: Equatable {
    let id: String
    let displayName: String
    let displayPrice: String
}

/// A transaction as seen by the app. Only `isVerified` ones can ever grant access.
struct StoreTransactionInfo: Equatable {
    let productID: String
    let isVerified: Bool
    let revocationDate: Date?

    var grantsAccess: Bool { isVerified && revocationDate == nil }
}

enum StorePurchaseOutcome: Equatable {
    case purchased(StoreTransactionInfo)
    /// StoreKit returned a transaction that failed verification (never grants Premium).
    case unverified
    case userCancelled
    /// Waiting for approval (Ask to Buy, SCA…). Premium arrives later through transaction updates.
    case pending
}

/// The StoreKit operations the app uses. `AppStoreClient` is the live implementation; tests use doubles.
protocol StoreClient: AnyObject {
    func product(id: String) async throws -> StoreProductInfo?
    func purchase(productID: String) async throws -> StorePurchaseOutcome
    /// Current entitlements as StoreKit reports them (works offline from the local receipt).
    func currentEntitlements() async -> [StoreTransactionInfo]
    /// Re-syncs purchases with the App Store (may ask the user to sign in).
    func sync() async throws
    /// Called for every transaction update (purchases on other devices, approvals, refunds/revocations).
    func observeTransactionUpdates(_ handler: @escaping @Sendable () async -> Void) -> Task<Void, Never>
}

// MARK: - Developer overrides (Debug builds only)

#if DEBUG
/// Switches for builds run from Xcode, so the developer can test free/premium and ads quickly.
/// Compiled out of Release builds; never used as proof of purchase in shipped apps.
final class DeveloperOverrides {
    enum PremiumOverride: String, CaseIterable {
        case none, forceFree, forcePremium

        var title: String {
            switch self {
            case .none: return "依購買紀錄"
            case .forceFree: return "免費版"
            case .forcePremium: return "完整版"
            }
        }
    }

    static let shared = DeveloperOverrides()
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var premium: PremiumOverride {
        get { defaults.string(forKey: "dev.premiumOverride").flatMap(PremiumOverride.init) ?? .none }
        set { defaults.set(newValue.rawValue, forKey: "dev.premiumOverride") }
    }

    /// When false, no ads are requested even for free users.
    var adsEnabled: Bool {
        get { defaults.object(forKey: "dev.adsEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "dev.adsEnabled") }
    }
}
#endif

// MARK: - Entitlement service

enum PurchaseResult: Equatable {
    case purchased
    case cancelled
    case pending
    case failed(String)
}

enum RestoreResult: Equatable {
    case restored
    case nothingToRestore
    case failed(String)
}

/// Single source of truth for Premium. Premium is granted only from verified, unrevoked StoreKit
/// transactions (`Transaction.currentEntitlements`), never from a stored flag.
@MainActor
final class EntitlementService {
    private let store: StoreClient
    private var updatesTask: Task<Void, Never>?
    private let logger = Logger(subsystem: "FoodManager.HowCode", category: "Entitlements")
    #if DEBUG
    private let developer: DeveloperOverrides?
    #endif

    /// What StoreKit says (before any developer override).
    private(set) var purchasedState: EntitlementState = .unknown
    private(set) var product: StoreProductInfo?

    #if DEBUG
    init(store: StoreClient, developer: DeveloperOverrides? = .shared) {
        self.store = store
        self.developer = developer
    }
    #else
    init(store: StoreClient) {
        self.store = store
    }
    #endif

    deinit { updatesTask?.cancel() }

    /// Effective state the UI uses.
    var state: EntitlementState {
        #if DEBUG
        switch developer?.premium ?? .none {
        case .forceFree: return .free
        case .forcePremium: return .premium
        case .none: break
        }
        #endif
        return purchasedState
    }

    var isPremium: Bool { state == .premium }

    /// Feature check used by the rest of the app (no StoreKit types leak out).
    func isEnabled(_ feature: PremiumFeature) -> Bool {
        feature.isImplemented && isPremium
    }

    /// Call once at launch: reads current entitlements and starts observing updates.
    func start() {
        guard updatesTask == nil else { return }
        updatesTask = store.observeTransactionUpdates { [weak self] in await self?.refresh() }
        Task { await refresh() }
    }

    /// Recomputes Premium from StoreKit's current, verified entitlements (also handles refunds/revocations).
    func refresh() async {
        let entitlements = await store.currentEntitlements()
        let premium = entitlements.contains { $0.productID == StoreProducts.premium && $0.grantsAccess }
        setPurchased(premium ? .premium : .free)
    }

    /// Loads the localized product (price) for the purchase screen.
    func loadProduct() async throws -> StoreProductInfo? {
        let info = try await store.product(id: StoreProducts.premium)
        product = info
        return info
    }

    func purchase() async -> PurchaseResult {
        do {
            switch try await store.purchase(productID: StoreProducts.premium) {
            case let .purchased(transaction):
                guard transaction.productID == StoreProducts.premium, transaction.grantsAccess else {
                    return .failed("購買無法驗證，未解鎖完整版。")
                }
                setPurchased(.premium)
                return .purchased
            case .unverified:
                logger.error("Rejected an unverified transaction")
                return .failed("購買無法驗證，未解鎖完整版。")
            case .userCancelled:
                return .cancelled
            case .pending:
                return .pending
            }
        } catch {
            logger.error("Purchase failed: \(String(describing: error), privacy: .private)")
            return .failed("購買未完成，請確認網路連線後再試一次。")
        }
    }

    /// Restoring only succeeds when StoreKit then reports a verified Premium entitlement.
    func restore() async -> RestoreResult {
        do {
            try await store.sync()
        } catch {
            logger.error("Restore failed: \(String(describing: error), privacy: .private)")
            return .failed("無法連線到 App Store，請稍後再試。")
        }
        await refresh()
        return purchasedState == .premium ? .restored : .nothingToRestore
    }

    #if DEBUG
    /// Re-publishes after a developer switch changed.
    func developerOverridesChanged() {
        NotificationCenter.default.post(name: .entitlementsDidChange, object: self)
    }
    #endif

    private func setPurchased(_ new: EntitlementState) {
        let before = state
        purchasedState = new
        if state != before { NotificationCenter.default.post(name: .entitlementsDidChange, object: self) }
    }
}
