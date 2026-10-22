import CoreGraphics
import Foundation

enum MagnetSource: String, Codable, Equatable {
    case builtIn
    case photo
}

/// How a magnet's picture is presented. Tapping a selected magnet in the editor cycles through them.
enum MagnetStyle: String, Codable, CaseIterable, Equatable {
    /// The picture as-is (transparent areas stay transparent).
    case original
    /// Square photo with a wide bottom margin.
    case polaroid
    /// White border, square corners.
    case squareFrame
    /// White border, rounded corners.
    case roundedFrame
    /// White border with a wavy, scalloped edge.
    case stamp
    case circle
    case star

    var title: String {
        switch self {
        case .original: return "原始形狀"
        case .polaroid: return "拍立得"
        case .squareFrame: return "白框"
        case .roundedFrame: return "圓角白框"
        case .stamp: return "郵票花邊"
        case .circle: return "圓形"
        case .star: return "星星"
        }
    }

    var next: MagnetStyle {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }

    static func defaultStyle(for source: MagnetSource) -> MagnetStyle {
        source == .photo ? .squareFrame : .original
    }

    /// Height / width of the whole magnet for a picture with `imageAspect` (= height / width).
    func outerAspect(imageAspect: Double) -> Double {
        let image = imageAspect.isFinite && imageAspect > 0 ? imageAspect : 1
        let layout = MagnetStyleLayout(self)
        switch self {
        case .original: return image
        case .polaroid: return layout.top + (1 - 2 * layout.side) + layout.bottom
        case .squareFrame, .roundedFrame, .stamp: return (1 - 2 * layout.side) * image + layout.top + layout.bottom
        case .circle, .star: return 1
        }
    }
}

/// Border sizes as fractions of the magnet's width (shared by layout math and drawing).
struct MagnetStyleLayout {
    let side: Double
    let top: Double
    let bottom: Double

    init(_ style: MagnetStyle) {
        switch style {
        case .original, .circle, .star: (side, top, bottom) = (0, 0, 0)
        case .polaroid: (side, top, bottom) = (0.06, 0.06, 0.24)
        case .squareFrame, .roundedFrame: (side, top, bottom) = (0.06, 0.06, 0.06)
        case .stamp: (side, top, bottom) = (0.1, 0.1, 0.1)
        }
    }
}

/// One decoration on a fridge door. Position and size are normalized to the visible door surface
/// (`FridgeTemplate.closedDoorRect`), so the arrangement looks the same on every screen size.
struct FridgeMagnet: Codable, Equatable, Identifiable {
    let id: UUID
    var fridgeID: UUID
    var source: MagnetSource
    /// `MagnetCatalog` item ID (built-in magnets).
    var builtInAssetID: String?
    /// File in `MagnetImageStore` (photo magnets). Several magnets may share one image.
    var localImageID: UUID?
    /// Center as a fraction of the door width / height.
    var centerX: Double
    var centerY: Double
    /// Size as a fraction of the door width / height (aspect ratio of the artwork is kept by scaling both).
    var width: Double
    var height: Double
    var rotation: Double
    /// Higher draws on top. Kept contiguous (0, 1, 2…) by `MagnetDraft`.
    var zIndex: Int
    var createdAt: Date
    var updatedAt: Date
    var style: MagnetStyle = .original
}

extension FridgeMagnet {
    private enum CodingKeys: String, CodingKey {
        case id, fridgeID, source, builtInAssetID, localImageID, centerX, centerY, width, height, rotation, zIndex, createdAt, updatedAt, style
    }

    /// `style` is optional in the file: magnets from before styles existed get their source's default.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        fridgeID = try c.decode(UUID.self, forKey: .fridgeID)
        source = try c.decode(MagnetSource.self, forKey: .source)
        builtInAssetID = try c.decodeIfPresent(String.self, forKey: .builtInAssetID)
        localImageID = try c.decodeIfPresent(UUID.self, forKey: .localImageID)
        centerX = try c.decode(Double.self, forKey: .centerX)
        centerY = try c.decode(Double.self, forKey: .centerY)
        width = try c.decode(Double.self, forKey: .width)
        height = try c.decode(Double.self, forKey: .height)
        rotation = try c.decode(Double.self, forKey: .rotation)
        zIndex = try c.decode(Int.self, forKey: .zIndex)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        style = try c.decodeIfPresent(MagnetStyle.self, forKey: .style) ?? MagnetStyle.defaultStyle(for: source)
    }
}

/// Limits and conversions between door-relative values and points. Pure math, no UIKit.
enum MagnetGeometry {
    /// Width limits as a fraction of the door width.
    static let minWidth = 0.12
    static let maxWidth = 0.9
    /// The center stays on the door, so at least a quarter of every magnet remains visible and grabbable.
    static let centerRange = 0.0...1.0
    static let defaultWidth = 0.34

    /// The rect an image of `content` size occupies when aspect-fit into `bounds` (like `.scaleAspectFit`).
    static func aspectFitRect(content: CGSize, in bounds: CGRect) -> CGRect {
        guard content.width > 0, content.height > 0, bounds.width > 0, bounds.height > 0 else { return .zero }
        let scale = min(bounds.width / content.width, bounds.height / content.height)
        let size = CGSize(width: content.width * scale, height: content.height * scale)
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
    }

    /// The door surface in view coordinates for artwork drawn aspect-fit into `bounds`.
    static func doorRect(template: FridgeTemplate, in bounds: CGRect) -> CGRect {
        let art = aspectFitRect(content: template.closedImageSize, in: bounds)
        let door = template.closedDoorRect
        return CGRect(x: art.minX + door.x * art.width, y: art.minY + door.y * art.height,
                      width: door.width * art.width, height: door.height * art.height)
    }

    static func center(of magnet: FridgeMagnet, in door: CGRect) -> CGPoint {
        CGPoint(x: door.minX + magnet.centerX * door.width, y: door.minY + magnet.centerY * door.height)
    }

    static func size(of magnet: FridgeMagnet, in door: CGRect) -> CGSize {
        CGSize(width: magnet.width * door.width, height: magnet.height * door.height)
    }

    static func normalizedPoint(_ point: CGPoint, in door: CGRect) -> (x: Double, y: Double)? {
        guard door.width > 0, door.height > 0 else { return nil }
        return (Double((point.x - door.minX) / door.width), Double((point.y - door.minY) / door.height))
    }

    /// Normalized size for a new magnet with the artwork's pixel aspect ratio on a door of `doorAspect` (width / height).
    static func initialSize(imageSize: CGSize, doorAspect: Double, width: Double = defaultWidth) -> (width: Double, height: Double) {
        guard imageSize.width > 0, imageSize.height > 0, doorAspect.isFinite, doorAspect > 0 else { return (width, width * doorAspect) }
        let imageAspect = Double(imageSize.height / imageSize.width)
        return (width, width * imageAspect * doorAspect)
    }

    /// Scale factor that keeps the width within limits.
    static func clampedScale(_ factor: Double, currentWidth: Double) -> Double {
        guard factor.isFinite, factor > 0, currentWidth > 0 else { return 1 }
        let target = min(max(currentWidth * factor, minWidth), maxWidth)
        return target / currentWidth
    }

    static func clampCenter(_ value: Double) -> Double {
        guard value.isFinite else { return 0.5 }
        return min(max(value, centerRange.lowerBound), centerRange.upperBound)
    }

    /// Angle in (-π, π].
    static func normalizedAngle(_ angle: Double) -> Double {
        guard angle.isFinite else { return 0 }
        var a = angle.truncatingRemainder(dividingBy: 2 * .pi)
        if a > .pi { a -= 2 * .pi }
        if a <= -.pi { a += 2 * .pi }
        return a
    }

    /// Stored values that are safe to render (finite, on the door, within size limits).
    static func isValid(_ magnet: FridgeMagnet) -> Bool {
        let values = [magnet.centerX, magnet.centerY, magnet.width, magnet.height, magnet.rotation]
        guard values.allSatisfy(\.isFinite) else { return false }
        let tolerance = 1e-6
        return centerRange.contains(magnet.centerX) && centerRange.contains(magnet.centerY)
            && magnet.width >= minWidth - tolerance && magnet.width <= maxWidth + tolerance
            && magnet.height > 0 && magnet.height <= 3
            && abs(magnet.rotation) <= .pi + tolerance
            && (magnet.source == .builtIn ? magnet.builtInAssetID?.isEmpty == false : magnet.localImageID != nil)
    }

    /// Brings stored values back into range (never drops a magnet). Used when loading.
    static func sanitized(_ magnet: FridgeMagnet) -> FridgeMagnet {
        var m = magnet
        m.centerX = clampCenter(m.centerX)
        m.centerY = clampCenter(m.centerY)
        let width = m.width.isFinite && m.width > 0 ? m.width : defaultWidth
        let height = m.height.isFinite && m.height > 0 ? m.height : width
        let scale = clampedScale(1, currentWidth: width) // brings width into range
        m.width = width * scale
        m.height = min(height * scale, 3)
        m.rotation = normalizedAngle(m.rotation)
        return m
    }
}

/// The editor's working copy. Every change happens here; storage is only touched on save.
struct MagnetDraft: Equatable {
    let fridgeID: UUID
    /// The arrangement when editing started (Cancel restores exactly this).
    let original: [FridgeMagnet]
    private(set) var magnets: [FridgeMagnet]
    /// Images imported during this session (deleted on cancel unless something saved still uses them).
    private(set) var importedImageIDs: Set<UUID> = []
    static let maxMagnets = 60

    init(fridgeID: UUID, magnets: [FridgeMagnet]) {
        self.fridgeID = fridgeID
        let ordered = magnets.sorted { ($0.zIndex, $0.createdAt) < ($1.zIndex, $1.createdAt) }
        original = ordered
        self.magnets = Self.renumbered(ordered)
    }

    var hasChanges: Bool { magnets != Self.renumbered(original) }
    var canAdd: Bool { magnets.count < Self.maxMagnets }

    /// Top-most first is `magnets.reversed()`; drawing order is `magnets`.
    func magnet(_ id: UUID) -> FridgeMagnet? { magnets.first { $0.id == id } }

    @discardableResult
    mutating func add(source: MagnetSource, builtInAssetID: String? = nil, localImageID: UUID? = nil,
                      size: (width: Double, height: Double), style: MagnetStyle? = nil,
                      now: Date = Date(), id: UUID = UUID()) -> FridgeMagnet? {
        guard canAdd else { return nil }
        // New magnets land near the middle, slightly staggered so they don't hide each other.
        let offset = Double(magnets.count % 5) * 0.04
        var magnet = FridgeMagnet(id: id, fridgeID: fridgeID, source: source, builtInAssetID: builtInAssetID,
                                  localImageID: localImageID, centerX: 0.5 + offset - 0.08, centerY: 0.4 + offset,
                                  width: size.width, height: size.height, rotation: 0, zIndex: magnets.count,
                                  createdAt: now, updatedAt: now, style: style ?? MagnetStyle.defaultStyle(for: source))
        let scale = MagnetGeometry.clampedScale(1, currentWidth: magnet.width)
        magnet.width *= scale
        magnet.height *= scale
        if let localImageID, source == .photo, !original.contains(where: { $0.localImageID == localImageID }) {
            importedImageIDs.insert(localImageID)
        }
        magnets.append(magnet)
        return magnet
    }

    /// Moves by a normalized delta; the center stays on the door.
    mutating func move(_ id: UUID, dx: Double, dy: Double, now: Date = Date()) {
        update(id, now: now) {
            $0.centerX = MagnetGeometry.clampCenter($0.centerX + dx)
            $0.centerY = MagnetGeometry.clampCenter($0.centerY + dy)
        }
    }

    mutating func setCenter(_ id: UUID, x: Double, y: Double, now: Date = Date()) {
        update(id, now: now) {
            $0.centerX = MagnetGeometry.clampCenter(x)
            $0.centerY = MagnetGeometry.clampCenter(y)
        }
    }

    /// Uniform scale (keeps the aspect ratio), limited to the min / max width.
    mutating func scale(_ id: UUID, by factor: Double, now: Date = Date()) {
        update(id, now: now) {
            let s = MagnetGeometry.clampedScale(factor, currentWidth: $0.width)
            $0.width *= s
            $0.height *= s
        }
    }

    mutating func rotate(_ id: UUID, by radians: Double, now: Date = Date()) {
        guard radians.isFinite else { return }
        update(id, now: now) { $0.rotation = MagnetGeometry.normalizedAngle($0.rotation + radians) }
    }

    /// Changes the presentation; the height follows the style's shape (width is kept, so it doesn't jump in size).
    mutating func setStyle(_ id: UUID, _ style: MagnetStyle, imageAspect: Double, doorAspect: Double, now: Date = Date()) {
        update(id, now: now) {
            $0.style = style
            let height = $0.width * style.outerAspect(imageAspect: imageAspect) * doorAspect
            if height.isFinite, height > 0 { $0.height = min(height, 3) }
        }
    }

    mutating func bringForward(_ id: UUID) { swapLayer(id, offset: 1) }
    mutating func sendBackward(_ id: UUID) { swapLayer(id, offset: -1) }

    /// Copy on top, slightly offset. Photo copies share the same image file (no duplicated bytes).
    @discardableResult
    mutating func duplicate(_ id: UUID, now: Date = Date(), newID: UUID = UUID()) -> FridgeMagnet? {
        guard canAdd, let source = magnet(id) else { return nil }
        let copy = FridgeMagnet(id: newID, fridgeID: fridgeID, source: source.source, builtInAssetID: source.builtInAssetID,
                            localImageID: source.localImageID,
                            centerX: MagnetGeometry.clampCenter(source.centerX + 0.06),
                            centerY: MagnetGeometry.clampCenter(source.centerY + 0.04),
                            width: source.width, height: source.height, rotation: source.rotation,
                            zIndex: magnets.count, createdAt: now, updatedAt: now, style: source.style)
        magnets.append(copy)
        return copy
    }

    mutating func delete(_ id: UUID) {
        magnets.removeAll { $0.id == id }
        magnets = Self.renumbered(magnets)
    }

    /// Image files this draft no longer needs if it is cancelled (imported now, not in the original).
    var imagesToDiscardOnCancel: Set<UUID> { importedImageIDs }

    var referencedImageIDs: Set<UUID> { Set(magnets.compactMap(\.localImageID)) }

    private mutating func update(_ id: UUID, now: Date, _ change: (inout FridgeMagnet) -> Void) {
        guard let index = magnets.firstIndex(where: { $0.id == id }) else { return }
        change(&magnets[index])
        magnets[index].updatedAt = now
    }

    private mutating func swapLayer(_ id: UUID, offset: Int) {
        guard let index = magnets.firstIndex(where: { $0.id == id }) else { return }
        let target = index + offset
        guard magnets.indices.contains(target) else { return }
        magnets.swapAt(index, target)
        magnets = Self.renumbered(magnets)
    }

    private static func renumbered(_ magnets: [FridgeMagnet]) -> [FridgeMagnet] {
        magnets.enumerated().map { index, magnet in
            var m = magnet
            m.zIndex = index
            return m
        }
    }
}
