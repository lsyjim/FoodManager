import CoreGraphics
import Foundation

enum LayoutValidationError: Error, Equatable {
    case outOfBounds(UUID)
    case tooSmall(UUID)
    case overlap(UUID, UUID)
    case duplicateID(UUID)
    case invalidName(UUID)
    case wrongZone(UUID)
    case typeNotAllowed(UUID)
    case storageTypeNotAllowed(UUID)
    case invalidOrder(UUID)

    var message: String {
        switch self {
        case .outOfBounds: return "隔層超出可編輯範圍"
        case .tooSmall: return "隔層高度太小"
        case .overlap: return "隔層互相重疊"
        case .duplicateID: return "隔層識別碼重複"
        case .invalidName: return "名稱不可空白，且最多 \(FridgeLayoutEngine.maxNameLength) 字"
        case .wrongZone: return "隔層所屬區域錯誤"
        case .typeNotAllowed: return "此區域不能放這種隔層"
        case .storageTypeNotAllowed: return "此區域不能設定這種儲存類型"
        case .invalidOrder: return "隔層順序錯誤"
        }
    }
}

/// Pure geometry + validation. No UIKit, no state — everything here is unit-testable.
enum FridgeLayoutEngine {
    /// Smallest height a user can add or shrink a compartment to (fraction of its zone). Together with the
    /// half-gap hit outset this keeps every touch target ≥ 44pt down to a 375pt-wide iPhone.
    static let minHeight: Double = 0.17
    /// Hard data-integrity floor used by validation. Lower than `minHeight` so layouts saved by Phase 1
    /// (min 0.12) stay valid and are never discarded; users can still enlarge them.
    static let absoluteMinHeight: Double = 0.12
    /// Vertical gap between stacked compartments (fraction of zone height).
    static let gap: Double = 0.015
    static let maxNameLength = 12
    static let tolerance: Double = 1e-6

    // MARK: - Geometry (normalized → screen)

    /// The rect an image occupies when aspect-fit into `bounds`.
    static func aspectFitRect(contentSize: CGSize, in bounds: CGRect) -> CGRect {
        guard contentSize.width > 0, contentSize.height > 0, bounds.width > 0, bounds.height > 0 else { return .zero }
        let scale = min(bounds.width / contentSize.width, bounds.height / contentSize.height)
        let size = CGSize(width: contentSize.width * scale, height: contentSize.height * scale)
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    /// Maps a unit-space rect into a concrete container rect.
    static func rect(for normalized: NormalizedRect, in container: CGRect) -> CGRect {
        CGRect(x: container.minX + normalized.x * container.width,
               y: container.minY + normalized.y * container.height,
               width: normalized.width * container.width,
               height: normalized.height * container.height)
    }

    /// Extra vertical hit area on each side of a compartment: half the gap, so neighbours never share a point.
    static func hitOutset(zoneHeight: CGFloat) -> CGFloat {
        CGFloat(gap) * zoneHeight / 2
    }

    /// Effective touch height of the smallest compartment a user can create in a zone of this height.
    static func minimumTouchHeight(zoneHeight: CGFloat) -> CGFloat {
        CGFloat(minHeight) * zoneHeight + 2 * hitOutset(zoneHeight: zoneHeight)
    }

    /// Screen frame of a zone, given where the open artwork is drawn.
    static func zoneFrame(_ zone: ZoneID, template: FridgeTemplate, imageFrame: CGRect) -> CGRect {
        rect(for: template.editableRect(for: zone), in: imageFrame)
    }

    // MARK: - Stacking

    /// Orders by `sortOrder`, renumbers 0…n-1 and stacks full-width bands from the top with `gap` between them.
    /// Heights are preserved; free space (if any) stays at the bottom of the zone.
    /// Position depends only on the user's order — never on `storageType`.
    static func pack(_ compartments: [Compartment]) -> [Compartment] {
        var y = 0.0
        return compartments
            .sorted { $0.sortOrder < $1.sortOrder }
            .enumerated()
            .map { index, compartment in
                var packed = compartment
                packed.sortOrder = index
                packed.normalizedFrame = NormalizedRect(x: 0, y: y, width: 1, height: compartment.normalizedFrame.height)
                y += compartment.normalizedFrame.height + gap
                return packed
            }
    }

    /// Fraction of the zone consumed by compartments and the gaps between them.
    static func usedHeight(_ compartments: [Compartment]) -> Double {
        guard !compartments.isEmpty else { return 0 }
        return compartments.reduce(0) { $0 + $1.normalizedFrame.height } + gap * Double(compartments.count - 1)
    }

    /// Height still available for one more compartment (accounts for the extra gap it would need).
    static func availableHeightForNewCompartment(in compartments: [Compartment]) -> Double {
        let extraGap = compartments.isEmpty ? 0 : gap
        return max(0, 1 - usedHeight(compartments) - extraGap)
    }

    // MARK: - Validation

    static func isValidName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.count <= maxNameLength
    }

    static func validate(_ compartments: [Compartment], in zone: ZoneID) -> [LayoutValidationError] {
        var errors: [LayoutValidationError] = []
        for c in compartments {
            let f = c.normalizedFrame
            if c.parentZoneID != zone { errors.append(.wrongZone(c.id)) }
            if !zone.allowedTypes.contains(c.type) { errors.append(.typeNotAllowed(c.id)) }
            if !zone.allowedStorageTypes.contains(c.storageType) { errors.append(.storageTypeNotAllowed(c.id)) }
            if !isValidName(c.name) { errors.append(.invalidName(c.id)) }
            if f.height < absoluteMinHeight - tolerance { errors.append(.tooSmall(c.id)) }
            if f.x < -tolerance || f.y < -tolerance || f.maxX > 1 + tolerance || f.maxY > 1 + tolerance
                || f.width <= 0 || f.height <= 0 {
                errors.append(.outOfBounds(c.id))
            }
        }
        // Sort orders must be unique and match the top-to-bottom position.
        let ordered = compartments.sorted { $0.sortOrder < $1.sortOrder }
        for (previous, next) in zip(ordered, ordered.dropFirst())
        where previous.sortOrder == next.sortOrder || next.normalizedFrame.y < previous.normalizedFrame.y {
            errors.append(.invalidOrder(next.id))
        }
        for i in compartments.indices {
            for j in compartments.indices where j > i {
                let a = compartments[i].normalizedFrame, b = compartments[j].normalizedFrame
                let overlapsX = a.x < b.maxX - tolerance && b.x < a.maxX - tolerance
                let overlapsY = a.y < b.maxY - tolerance && b.y < a.maxY - tolerance
                if overlapsX && overlapsY { errors.append(.overlap(compartments[i].id, compartments[j].id)) }
            }
        }
        return errors
    }

    static func validate(_ fridge: Fridge) -> [LayoutValidationError] {
        var errors = ZoneID.allCases.flatMap { validate(fridge.compartments(in: $0), in: $0) }
        var seen = Set<UUID>()
        for c in fridge.allCompartments where !seen.insert(c.id).inserted {
            errors.append(.duplicateID(c.id))
        }
        return errors
    }
}
