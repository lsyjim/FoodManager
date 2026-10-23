import Foundation

/// One quantity change on a shared food. Immutable once written; its `id` is also the CloudKit record name, so a
/// retried upload or a duplicate delivery can never be counted twice.
struct QuantityOp: Equatable {
    let id: UUID
    let foodID: UUID
    let delta: Decimal
    let createdAt: Date
}

/// Operation-based quantities for shared fridges: two people taking 1 and 2 of 5 at the same time end at 2, not at
/// whichever write arrived last. The food record keeps a base value; every change is a separate op record.
enum QuantityLedger {
    static let maxAbsoluteDelta: Decimal = 1_000_000
    /// How many folded op IDs a food remembers (to ignore late re-deliveries of ops already folded into the base).
    static let maxFoldedIDs = 1_000

    /// `base + Σ delta` over distinct ops that aren't folded yet, never below zero.
    static func quantity(base: Decimal, folded: Set<UUID>, ops: [QuantityOp]) -> Decimal {
        var seen = Set<UUID>()
        var total = base
        for op in ops where !folded.contains(op.id) && seen.insert(op.id).inserted {
            total += op.delta
        }
        return max(total, 0)
    }

    static func isValidDelta(_ delta: Decimal) -> Bool {
        delta != 0 && !delta.isNaN && abs(delta) <= maxAbsoluteDelta
    }

    struct Compaction: Equatable {
        let base: Decimal
        /// Folded IDs to store on the food (newest kept when over the cap), oldest first.
        let folded: [UUID]
        /// Op records that may now be deleted.
        let foldedOps: [UUID]
    }

    /// Folds ops older than `cutoff` into the base (done by the owner's device; the base may go negative so later ops
    /// still add up exactly). Newer ops stay separate, so a change still in flight on another device isn't lost.
    static func compact(base: Decimal, folded: [UUID], ops: [QuantityOp], olderThan cutoff: Date) -> Compaction {
        let alreadyFolded = Set(folded)
        var seen = Set<UUID>()
        var newBase = base
        var newlyFolded: [UUID] = []
        for op in ops.sorted(by: { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) })
        where op.createdAt < cutoff && !alreadyFolded.contains(op.id) && seen.insert(op.id).inserted {
            newBase += op.delta
            newlyFolded.append(op.id)
        }
        let allFolded = Array((folded + newlyFolded).suffix(maxFoldedIDs))
        return Compaction(base: newBase, folded: allFolded, foldedOps: newlyFolded)
    }
}
