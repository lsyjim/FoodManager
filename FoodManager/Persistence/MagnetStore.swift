import Foundation
import ImageIO
import SwiftData
import UIKit
import UniformTypeIdentifiers
import os

/// SwiftData row for one fridge magnet. Image bytes are never stored here: photo magnets point at a file
/// in `MagnetImageStore` by `localImageID`; built-in magnets point at a file in `BuiltInMagnets.bundle` by `builtInAssetID`.
@Model
final class MagnetRecord {
    @Attribute(.unique) var id: UUID
    var fridgeID: UUID
    var sourceRaw: String
    var builtInAssetID: String?
    var localImageID: UUID?
    var centerX: Double
    var centerY: Double
    var width: Double
    var height: Double
    var rotation: Double
    var zIndex: Int
    var createdAt: Date
    var updatedAt: Date
    /// Phase 4.3 addition (optional, so existing rows migrate untouched; nil = the source's default style).
    var styleRaw: String?

    init(_ magnet: FridgeMagnet) {
        id = magnet.id
        fridgeID = magnet.fridgeID
        sourceRaw = magnet.source.rawValue
        centerX = magnet.centerX
        centerY = magnet.centerY
        width = magnet.width
        height = magnet.height
        rotation = magnet.rotation
        zIndex = magnet.zIndex
        createdAt = magnet.createdAt
        updatedAt = magnet.updatedAt
        apply(magnet)
    }

    func apply(_ magnet: FridgeMagnet) {
        fridgeID = magnet.fridgeID
        sourceRaw = magnet.source.rawValue
        builtInAssetID = magnet.builtInAssetID
        localImageID = magnet.localImageID
        centerX = magnet.centerX
        centerY = magnet.centerY
        width = magnet.width
        height = magnet.height
        rotation = magnet.rotation
        zIndex = magnet.zIndex
        createdAt = magnet.createdAt
        updatedAt = magnet.updatedAt
        styleRaw = magnet.style.rawValue
    }

    var magnet: FridgeMagnet {
        let source = MagnetSource(rawValue: sourceRaw) ?? .builtIn
        return FridgeMagnet(id: id, fridgeID: fridgeID, source: source,
                            builtInAssetID: builtInAssetID, localImageID: localImageID, centerX: centerX, centerY: centerY,
                            width: width, height: height, rotation: rotation, zIndex: zIndex,
                            createdAt: createdAt, updatedAt: updatedAt,
                            style: styleRaw.flatMap(MagnetStyle.init(rawValue:)) ?? MagnetStyle.defaultStyle(for: source))
    }
}

protocol MagnetStore: AnyObject {
    /// One fridge's magnets, bottom layer first.
    func magnets(fridgeID: UUID) throws -> [FridgeMagnet]
    func allMagnets() throws -> [FridgeMagnet]
    /// Replaces one fridge's magnets in a single save (all or nothing).
    func replaceMagnets(_ magnets: [FridgeMagnet], fridgeID: UUID) throws
}

final class SwiftDataMagnetStore: MagnetStore {
    private let container: ModelContainer

    init(container: ModelContainer) { self.container = container }

    func magnets(fridgeID: UUID) throws -> [FridgeMagnet] {
        let descriptor = FetchDescriptor<MagnetRecord>(predicate: #Predicate { $0.fridgeID == fridgeID },
                                                       sortBy: [SortDescriptor(\.zIndex), SortDescriptor(\.createdAt)])
        return try ModelContext(container).fetch(descriptor).map(\.magnet)
    }

    func allMagnets() throws -> [FridgeMagnet] {
        try ModelContext(container).fetch(FetchDescriptor<MagnetRecord>(sortBy: [SortDescriptor(\.zIndex)])).map(\.magnet)
    }

    func replaceMagnets(_ magnets: [FridgeMagnet], fridgeID: UUID) throws {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let existing = try context.fetch(FetchDescriptor<MagnetRecord>(predicate: #Predicate { $0.fridgeID == fridgeID }))
        let byID = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let kept = Set(magnets.map(\.id))
        for record in existing where !kept.contains(record.id) { context.delete(record) }
        for magnet in magnets {
            if let record = byID[magnet.id] { record.apply(magnet) } else { context.insert(MagnetRecord(magnet)) }
        }
        do {
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }
}

enum MagnetImageError: Error, Equatable {
    case cancelled
    case unsupported
    case tooLarge
    case decodeFailed
    case writeFailed

    var message: String {
        switch self {
        case .cancelled: return "已取消"
        case .unsupported: return "不支援這種圖片格式，請換一張照片。"
        case .tooLarge: return "這張照片太大，無法使用。"
        case .decodeFailed: return "無法讀取這張照片，請換一張試試。"
        case .writeFailed: return "無法儲存照片（可能是儲存空間不足）。"
        }
    }
}

struct ImportedMagnetImage: Equatable {
    let id: UUID
    let pixelSize: CGSize
}

/// Downsampled magnet photos on disk (never in SwiftData). One file per image ID; magnets that share an image
/// (duplicates) point at the same file. Files are only removed by `removeUnreferenced`, after a successful save.
final class MagnetImageStore {
    /// Long side of the stored display image. A magnet is at most ~0.9 × door width (≈ 200 pt × 3 = 600 px),
    /// so 1024 px stays sharp on Retina while keeping files and memory small.
    static let displayMaxPixels = 1024
    static let thumbnailMaxPixels = 240
    /// Files larger than this are rejected before decoding.
    static let maxSourceBytes = 80 * 1_048_576
    /// Larger than any real photo; protects against decompression bombs.
    static let maxSourcePixels = 400_000_000.0

    let directory: URL
    private let cache = NSCache<NSString, UIImage>()
    private let fileManager = FileManager.default
    private let logger = Logger(subsystem: "FoodManager.HowCode", category: "Magnets")

    init(directory: URL) {
        self.directory = directory
        cache.countLimit = 40
    }

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Magnets", isDirectory: true)
    }

    // MARK: Import

    /// Decodes (with EXIF orientation applied), downsamples and stores an image. Never keeps the original.
    func importImage(at url: URL) throws -> ImportedMagnetImage {
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > Self.maxSourceBytes {
            throw MagnetImageError.tooLarge
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw MagnetImageError.unsupported
        }
        return try importImage(from: source)
    }

    func importImage(data: Data) throws -> ImportedMagnetImage {
        guard data.count <= Self.maxSourceBytes else { throw MagnetImageError.tooLarge }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw MagnetImageError.unsupported
        }
        return try importImage(from: source)
    }

    private func importImage(from source: CGImageSource) throws -> ImportedMagnetImage {
        guard CGImageSourceGetCount(source) > 0, CGImageSourceGetType(source) != nil else { throw MagnetImageError.unsupported }
        if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let w = properties[kCGImagePropertyPixelWidth] as? Double, let h = properties[kCGImagePropertyPixelHeight] as? Double,
           w * h > Self.maxSourcePixels {
            throw MagnetImageError.tooLarge
        }
        guard let display = Self.downsample(source, maxPixels: Self.displayMaxPixels),
              let thumbnail = Self.downsample(source, maxPixels: Self.thumbnailMaxPixels) else {
            throw MagnetImageError.decodeFailed
        }
        let id = UUID()
        try write(display, to: url(for: id, thumbnail: false))
        do {
            try write(thumbnail, to: url(for: id, thumbnail: true))
        } catch {
            remove(id)
            throw error
        }
        return ImportedMagnetImage(id: id, pixelSize: CGSize(width: display.width, height: display.height))
    }

    /// Stores bytes exported by `data(_:)` under their original ID (backup restore). The bytes are kept as-is,
    /// so a restored image is identical to the exported one; only the thumbnail is regenerated.
    func storeImageData(_ data: Data, id: UUID) throws {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0,
              let thumbnail = Self.downsample(source, maxPixels: Self.thumbnailMaxPixels) else {
            throw MagnetImageError.decodeFailed
        }
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url(for: id, thumbnail: false), options: .atomic)
        } catch {
            throw MagnetImageError.writeFailed
        }
        try write(thumbnail, to: url(for: id, thumbnail: true))
        cache.removeObject(forKey: id.uuidString as NSString)
    }

    // MARK: Read

    func exists(_ id: UUID) -> Bool { fileManager.fileExists(atPath: url(for: id, thumbnail: false).path) }

    /// Display image (cached; decoded once, never during gestures).
    func image(_ id: UUID) -> UIImage? {
        let key = id.uuidString as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let image = UIImage(contentsOfFile: url(for: id, thumbnail: false).path)?.preparingForDisplay() else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }

    func thumbnail(_ id: UUID) -> UIImage? { UIImage(contentsOfFile: url(for: id, thumbnail: true).path) }

    func data(_ id: UUID) -> Data? { try? Data(contentsOf: url(for: id, thumbnail: false)) }

    func pixelSize(_ id: UUID) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url(for: id, thumbnail: false) as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = properties[kCGImagePropertyPixelWidth] as? CGFloat, let h = properties[kCGImagePropertyPixelHeight] as? CGFloat else {
            return nil
        }
        return CGSize(width: w, height: h)
    }

    func storedImageIDs() -> Set<UUID> {
        let names = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
        return Set(names.compactMap { name in
            name.hasSuffix(".img") ? UUID(uuidString: String(name.dropLast(4))) : nil
        })
    }

    // MARK: Delete

    func remove(_ id: UUID) {
        try? fileManager.removeItem(at: url(for: id, thumbnail: false))
        try? fileManager.removeItem(at: url(for: id, thumbnail: true))
        cache.removeObject(forKey: id.uuidString as NSString)
    }

    /// Deletes every stored image not in `referenced`. Call only after the references were committed.
    func removeUnreferenced(keeping referenced: Set<UUID>) {
        for id in storedImageIDs() where !referenced.contains(id) { remove(id) }
    }

    // MARK: Private

    private func url(for id: UUID, thumbnail: Bool) -> URL {
        directory.appendingPathComponent(id.uuidString + (thumbnail ? ".thumb" : ".img"))
    }

    private static func downsample(_ source: CGImageSource, maxPixels: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true, // applies EXIF orientation
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// PNG when the image has transparency, otherwise JPEG (smaller). Written atomically.
    private func write(_ image: CGImage, to url: URL) throws {
        let hasAlpha = ![.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
        let data = NSMutableData()
        let type = (hasAlpha ? UTType.png : UTType.jpeg).identifier as CFString
        guard let destination = CGImageDestinationCreateWithData(data, type, 1, nil) else { throw MagnetImageError.writeFailed }
        CGImageDestinationAddImage(destination, image, hasAlpha ? nil : [kCGImageDestinationLossyCompressionQuality: 0.88] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw MagnetImageError.writeFailed }
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try (data as Data).write(to: url, options: .atomic)
        } catch {
            logger.error("Writing magnet image failed: \(String(describing: error), privacy: .private)")
            throw MagnetImageError.writeFailed
        }
    }
}

/// Loading, committing and cleaning up magnets for the app.
final class MagnetLibrary {
    let store: MagnetStore
    let images: MagnetImageStore
    let catalog: MagnetCatalog
    private let logger = Logger(subsystem: "FoodManager.HowCode", category: "Magnets")

    init(store: MagnetStore, images: MagnetImageStore, catalog: MagnetCatalog = .shared) {
        self.store = store
        self.images = images
        self.catalog = catalog
    }

    /// A fridge's magnets, with stored values brought back into range.
    func magnets(fridgeID: UUID) throws -> [FridgeMagnet] {
        try store.magnets(fridgeID: fridgeID).map(MagnetGeometry.sanitized)
    }

    /// Saves the draft (one save). Image files that nothing references any more are removed afterwards;
    /// if saving fails, nothing is removed and the draft stays valid for a retry.
    func commit(_ draft: MagnetDraft) throws {
        try store.replaceMagnets(draft.magnets, fridgeID: draft.fridgeID)
        removeUnreferencedImages()
    }

    /// Cancel: drops images imported during the session that nothing saved refers to.
    func discard(_ draft: MagnetDraft) {
        guard let referenced = try? Set(store.allMagnets().compactMap(\.localImageID)) else { return }
        for id in draft.imagesToDiscardOnCancel where !referenced.contains(id) { images.remove(id) }
    }

    /// Removes image files no stored magnet (of any fridge) refers to. Skipped if magnets can't be read.
    func removeUnreferencedImages() {
        do {
            images.removeUnreferenced(keeping: Set(try store.allMagnets().compactMap(\.localImageID)))
        } catch {
            logger.error("Skipping magnet image cleanup: \(String(describing: error), privacy: .private)")
        }
    }

    /// Image for a magnet: bundled asset or stored photo. nil if the artwork is missing.
    func image(for magnet: FridgeMagnet) -> UIImage? {
        switch magnet.source {
        case .builtIn: return magnet.builtInAssetID.flatMap(catalog.image(id:))
        case .photo: return magnet.localImageID.flatMap(images.image)
        }
    }
}
