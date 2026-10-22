import StoreKit

/// Live StoreKit 2 implementation. Verified transactions are finished; unverified ones never grant access.
final class AppStoreClient: StoreClient {
    private var products: [String: Product] = [:]

    func product(id: String) async throws -> StoreProductInfo? {
        guard let product = try await Product.products(for: [id]).first else { return nil }
        products[id] = product
        return StoreProductInfo(id: product.id, displayName: product.displayName, displayPrice: product.displayPrice)
    }

    func purchase(productID: String) async throws -> StorePurchaseOutcome {
        let product: Product
        if let cached = products[productID] {
            product = cached
        } else if let fetched = try await Product.products(for: [productID]).first {
            product = fetched
        } else {
            throw StoreKitError.notAvailableInStorefront
        }
        // StoreKit shows the system purchase confirmation sheet.
        switch try await product.purchase() {
        case let .success(.verified(transaction)):
            await transaction.finish()
            return .purchased(Self.info(transaction, verified: true))
        case .success(.unverified):
            return .unverified
        case .userCancelled:
            return .userCancelled
        case .pending:
            return .pending
        @unknown default:
            return .userCancelled
        }
    }

    func currentEntitlements() async -> [StoreTransactionInfo] {
        var result: [StoreTransactionInfo] = []
        for await entitlement in Transaction.currentEntitlements {
            switch entitlement {
            case let .verified(transaction): result.append(Self.info(transaction, verified: true))
            case let .unverified(transaction, _): result.append(Self.info(transaction, verified: false))
            }
        }
        return result
    }

    func sync() async throws {
        try await AppStore.sync()
    }

    func observeTransactionUpdates(_ handler: @escaping @Sendable () async -> Void) -> Task<Void, Never> {
        Task.detached {
            for await update in Transaction.updates {
                if case let .verified(transaction) = update { await transaction.finish() }
                await handler()
            }
        }
    }

    private static func info(_ transaction: Transaction, verified: Bool) -> StoreTransactionInfo {
        StoreTransactionInfo(productID: transaction.productID, isVerified: verified, revocationDate: transaction.revocationDate)
    }
}
