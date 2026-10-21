import CryptoKit
import Foundation

/// What happened when a stored layout was loaded.
enum LayoutRecovery: Equatable {
    /// Stored layout was valid and is used as-is.
    case none
    /// Stored layout decoded but was invalid (overlaps, bad sizes…). Compartments were kept with their
    /// original IDs, names and classifications and only their geometry was re-packed.
    case repaired
    /// Stored layout could not be decoded at all. A default layout with *deterministic* IDs is shown,
    /// so repeated launches never mint new IDs. Food may now reference compartments that no longer exist.
    case replacedWithDefault

    var needsConfirmation: Bool { self != .none }
}

struct FridgeLoadResult: Equatable {
    var fridge: Fridge
    var recovery: LayoutRecovery
}

/// Non-destructive layout repair. Works in memory only; persisting the result is the caller's decision
/// (the UI asks the user before overwriting the original bytes).
enum FridgeLayoutRepair {
    /// Repairs one zone, keeping every compartment's identity. Returns nil if the zone cannot hold all of
    /// them at the minimum size (then nothing is dropped silently — the caller falls back instead).
    static func repair(_ compartments: [Compartment], in zone: ZoneID) -> [Compartment]? {
        guard !compartments.isEmpty else { return [] }
        var seenIDs = Set<UUID>()
        var fixed: [Compartment] = []
        let ordered = compartments.sorted { ($0.sortOrder, $0.normalizedFrame.y) < ($1.sortOrder, $1.normalizedFrame.y) }
        for (index, original) in ordered.enumerated() {
            // A duplicated ID cannot be kept twice; the duplicate gets a deterministic new ID.
            let id = seenIDs.insert(original.id).inserted ? original.id
                : deterministicID(seed: original.id, salt: "duplicate-\(index)")
            seenIDs.insert(id)
            var compartment = Compartment(id: id, parentZoneID: zone, name: original.name, type: original.type,
                                          storageType: original.storageType, sortOrder: index,
                                          normalizedFrame: original.normalizedFrame)
            if !zone.allowedTypes.contains(compartment.type) { compartment.type = zone.allowedTypes[0] }
            // Only an *invalid* classification is replaced; a valid frozen compartment stays frozen.
            if !zone.allowedStorageTypes.contains(compartment.storageType) { compartment.storageType = zone.defaultStorageType }
            if !FridgeLayoutEngine.isValidName(compartment.name) {
                compartment.name = "\(compartment.type.displayName) \(index + 1)"
            }
            let height = compartment.normalizedFrame.height
            compartment.normalizedFrame.height = height.isFinite ? max(height, FridgeLayoutEngine.absoluteMinHeight)
                                                                 : FridgeLayoutEngine.minHeight
            fixed.append(compartment)
        }

        // Shrink proportionally if the heights no longer fit, never below the data floor.
        let gaps = FridgeLayoutEngine.gap * Double(fixed.count - 1)
        let available = 1 - gaps
        let total = fixed.reduce(0) { $0 + $1.normalizedFrame.height }
        if total > available {
            let floor = FridgeLayoutEngine.absoluteMinHeight
            guard Double(fixed.count) * floor <= available + FridgeLayoutEngine.tolerance else { return nil }
            let flexible = total - Double(fixed.count) * floor
            let budget = available - Double(fixed.count) * floor
            for i in fixed.indices {
                let extra = fixed[i].normalizedFrame.height - floor
                fixed[i].normalizedFrame.height = ((floor + extra * budget / flexible) * 1000).rounded(.down) / 1000
            }
        }
        let packed = FridgeLayoutEngine.pack(fixed)
        return FridgeLayoutEngine.validate(packed, in: zone).isEmpty ? packed : nil
    }

    /// Repairs a whole fridge; nil if any zone can't be repaired without dropping compartments.
    static func repair(_ fridge: Fridge) -> Fridge? {
        var repaired = fridge
        for zone in ZoneID.allCases {
            guard let compartments = repair(fridge.compartments(in: zone), in: zone) else { return nil }
            repaired.setCompartments(compartments, in: zone)
        }
        return FridgeLayoutEngine.validate(repaired).isEmpty ? repaired : nil
    }

    /// Stable UUID derived from a seed, so the same damaged record always yields the same fallback IDs.
    static func deterministicID(seed: UUID, salt: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data("\(seed.uuidString)/\(salt)".utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50 // version 5-style
        bytes[8] = (bytes[8] & 0x3F) | 0x80 // RFC 4122 variant
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
