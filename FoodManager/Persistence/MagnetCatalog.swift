import ImageIO
import UIKit

/// One built-in magnet: an image file in `BuiltInMagnets.bundle`. Its ID is the file name without extension,
/// so it stays stable across builds (and in backups) as long as the file isn't renamed.
struct MagnetCatalogItem: Equatable {
    let id: String
    let url: URL
}

/// Built-in magnets, found by scanning `FoodManager/BuiltInMagnets.bundle` in the app bundle.
///
/// To add one: drop a PNG / JPEG / HEIC / WebP into that folder and build — no code or asset-catalog changes.
/// Images are shown in file-name order (prefix with numbers, e.g. `01-daisy.png`, to choose the order).
/// Transparent PNGs keep their shape in the 原始形狀 style. Nothing is downloaded.
final class MagnetCatalog {
    static let shared = MagnetCatalog(directory: Bundle.main.url(forResource: "BuiltInMagnets", withExtension: "bundle"))
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "webp"]

    let items: [MagnetCatalogItem]
    private let images = NSCache<NSString, UIImage>()
    private let thumbnails = NSCache<NSString, UIImage>()

    init(directory: URL?) {
        let files = directory.flatMap { try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil) } ?? []
        items = files
            .filter { Self.imageExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .map { MagnetCatalogItem(id: $0.deletingPathExtension().lastPathComponent, url: $0) }
        images.countLimit = 30
    }

    func item(id: String) -> MagnetCatalogItem? { items.first { $0.id == id } }

    /// Display image, downsampled once (large source files never sit in memory at full size).
    func image(id: String) -> UIImage? {
        cached(id, in: images, maxPixels: MagnetImageStore.displayMaxPixels)
    }

    /// Small image for the picker.
    func thumbnail(id: String) -> UIImage? {
        cached(id, in: thumbnails, maxPixels: 300)
    }

    private func cached(_ id: String, in cache: NSCache<NSString, UIImage>, maxPixels: Int) -> UIImage? {
        if let image = cache.object(forKey: id as NSString) { return image }
        guard let url = item(id: id)?.url,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxPixels,
                  kCGImageSourceShouldCacheImmediately: true,
              ] as CFDictionary) else { return nil }
        let image = UIImage(cgImage: cgImage)
        cache.setObject(image, forKey: id as NSString)
        return image
    }
}
