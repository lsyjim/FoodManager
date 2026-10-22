import Foundation
import ImageIO
import SwiftData
import UIKit
import UniformTypeIdentifiers
import os

/// SwiftData row for one fridge magnet. Image bytes are never stored here: photo magnets point at a file
/// in `MagnetImageStore` by `localImageID`; built-in magnets point at a file in `BuiltInMagnets.bundle` by `builtInAssetID`.
/// CloudKit-compatible: defaults everywhere, no unique constraint (see `FridgeRecord`).
@Model
final class MagnetRecord {
    var id: UUID = UUID()
    var fridgeID: UUID = UUID()
    var sourceRaw: String = "builtIn"
    var builtInAssetID: String?
    var localImageID: UUID?
    var centerX: Double = 0.5
    var centerY: Double = 0.5
    var width: Double = 0.3
    var height: Double = 0.3
    var rotation: Double = 0
    var zIndex: Int = 0
    var createdAt: Date = Date.now
    var updatedAt: Date = Date.now
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

/// Photo bytes of a photo magnet, synced to iCloud. `externalStorage` keeps the bytes out of the SQLite row;
/// CloudKit mirrors them as a CKAsset in the user's private database (never public). One record per image ID,
/// shared by every magnet that shows the photo, so duplicating a magnet never uploads it again.
@Model
final class MagnetImageRecord {
    var id: UUID = UUID()
    /// The stored display-size image (≤ 1024 px, PNG or JPEG) — never the original photo.
    @Attribute(.externalStorage) var data: Data?
    var createdAt: Date = Date.now

    init(id: UUID, data: Data) {
        self.id = id
        self.data = data
        createdAt = .now
    }
}

protocol MagnetStore: AnyObject {
    /// One fridge's magnets, bottom layer first.
    func magnets(fridgeID: UUID) throws -> [FridgeMagnet]
    func allMagnets() throws -> [FridgeMagnet]
    /// Replaces one fridge's magnets in a single save (all or nothing). `newImages` are stored as synced image
    /// records (if not stored yet). Image records the fridge's previous magnets used and nothing uses any more
    /// are deleted in the same save.
    func replaceMagnets(_ magnets: [FridgeMagnet], fridgeID: UUID, newImages: [UUID: Data]) throws
    /// Synced bytes of a photo (nil until they arrive from iCloud).
    func imageData(id: UUID) throws -> Data?
    func storedImageIDs() throws -> Set<UUID>
    /// Adds image records for photos that only exist as local files (one-time upgrade to synced photos).
    func addImages(_ images: [UUID: Data]) throws
}

final class SwiftDataMagnetStore: MagnetStore {
    private let container: ModelContainer

    init(container: ModelContainer) { self.container = container }

    private func makeContext() -> ModelContext {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        return context
    }

    func magnets(fridgeID: UUID) throws -> [FridgeMagnet] {
        let descriptor = FetchDescriptor<MagnetRecord>(predicate: #Predicate { $0.fridgeID == fridgeID })
        return Self.ordered(SyncedRecords.unique(try makeContext().fetch(descriptor)).map(\.magnet))
    }

    func allMagnets() throws -> [FridgeMagnet] {
        Self.ordered(SyncedRecords.unique(try makeContext().fetch(FetchDescriptor<MagnetRecord>())).map(\.magnet))
    }

    /// Bottom layer first; equal layers (two devices adding at once) keep a stable order.
    private static func ordered(_ magnets: [FridgeMagnet]) -> [FridgeMagnet] {
        magnets.sorted { ($0.zIndex, $0.createdAt, $0.id.uuidString) < ($1.zIndex, $1.createdAt, $1.id.uuidString) }
    }

    func replaceMagnets(_ magnets: [FridgeMagnet], fridgeID: UUID, newImages: [UUID: Data]) throws {
        let context = makeContext()
        let existing = try context.fetch(FetchDescriptor<MagnetRecord>(predicate: #Predicate { $0.fridgeID == fridgeID }))
        let previousImages = Set(existing.compactMap(\.localImageID))
        let byID = Dictionary(grouping: existing, by: \.id)
        let kept = Set(magnets.map(\.id))
        for record in existing where !kept.contains(record.id) { context.delete(record) }
        for magnet in magnets {
            if let records = byID[magnet.id] {
                for record in records { record.apply(magnet) }
            } else {
                context.insert(MagnetRecord(magnet))
            }
        }
        try insertMissingImages(newImages, in: context)
        let otherFridges = try context.fetch(FetchDescriptor<MagnetRecord>(predicate: #Predicate { $0.fridgeID != fridgeID }))
        let remainingHere = Set(magnets.compactMap(\.localImageID))
        try MagnetRecordCleanup.deleteImages(previousImages.subtracting(remainingHere), stillUsedBy: otherFridges, in: context)
        try save(context)
    }

    func imageData(id: UUID) throws -> Data? {
        try makeContext().fetch(FetchDescriptor<MagnetImageRecord>(predicate: #Predicate { $0.id == id }))
            .compactMap(\.data).first
    }

    func storedImageIDs() throws -> Set<UUID> {
        Set(try makeContext().fetch(FetchDescriptor<MagnetImageRecord>()).filter { $0.data != nil }.map(\.id))
    }

    func addImages(_ images: [UUID: Data]) throws {
        guard !images.isEmpty else { return }
        let context = makeContext()
        try insertMissingImages(images, in: context)
        try save(context)
    }

    private func insertMissingImages(_ images: [UUID: Data], in context: ModelContext) throws {
        for (id, data) in images {
            let existing = try context.fetch(FetchDescriptor<MagnetImageRecord>(predicate: #Predicate { $0.id == id }))
            if existing.isEmpty { context.insert(MagnetImageRecord(id: id, data: data)) }
        }
    }

    private func save(_ context: ModelContext) throws {
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

    /// The photo cache that belongs to `container`: the real folder only for the real (default) store. Any other
    /// store — in memory, or a file elsewhere (tests) — gets its own folder, so cleaning up after one database can
    /// never delete another database's photos.
    static func directory(for container: ModelContainer) -> URL {
        guard let configuration = container.configurations.first else { return scratchDirectory(named: "Unknown") }
        if configuration.isStoredInMemoryOnly { return scratchDirectory(named: "InMemory-\(ObjectIdentifier(container).hashValue)") }
        if configuration.url.standardizedFileURL == SwiftDataFridgeStore.defaultStoreURL.standardizedFileURL { return defaultDirectory }
        return configuration.url.deletingLastPathComponent()
            .appendingPathComponent("Magnets-" + configuration.url.deletingPathExtension().lastPathComponent, isDirectory: true)
    }

    private static func scratchDirectory(named name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("MagnetCache/\(name)", isDirectory: true)
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

    /// Saves the draft (one save, including the bytes of newly added photos so they sync). Local image files that
    /// nothing references any more are removed afterwards; if saving fails, nothing is removed and the draft stays
    /// valid for a retry.
    func commit(_ draft: MagnetDraft) throws {
        let stored = (try? store.storedImageIDs()) ?? []
        var newImages: [UUID: Data] = [:]
        for id in draft.referencedImageIDs where !stored.contains(id) {
            // A photo whose bytes haven't arrived from iCloud yet has no file either: its record comes later.
            if let data = images.data(id) { newImages[id] = data }
        }
        try store.replaceMagnets(draft.magnets, fridgeID: draft.fridgeID, newImages: newImages)
        removeUnreferencedImages()
    }

    /// One-time (and idempotent) upgrade: photos saved before iCloud sync only exist as local files. Gives each
    /// referenced photo a synced image record. Returns how many were added.
    @discardableResult
    func backfillImageRecords() throws -> Int {
        let stored = try store.storedImageIDs()
        var missing: [UUID: Data] = [:]
        for id in Set(try store.allMagnets().compactMap(\.localImageID)) where !stored.contains(id) {
            if let data = images.data(id) { missing[id] = data }
        }
        try store.addImages(missing)
        return missing.count
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
        case .photo: return magnet.localImageID.flatMap(photo(id:))
        }
    }

    /// Local cache first; otherwise the synced bytes are written to the cache. nil while they haven't arrived
    /// (the magnet then shows a neutral placeholder and keeps its place).
    private func photo(id: UUID) -> UIImage? {
        if let image = images.image(id) { return image }
        guard let data = try? store.imageData(id: id) else { return nil }
        do {
            try images.storeImageData(data, id: id)
        } catch {
            logger.error("Caching a synced magnet photo failed: \(String(describing: error), privacy: .private)")
            return nil
        }
        return images.image(id)
    }

    /// Bytes for a backup: the local cache, else the synced record.
    func photoData(id: UUID) -> Data? {
        images.data(id) ?? (try? store.imageData(id: id)) ?? nil
    }
}
