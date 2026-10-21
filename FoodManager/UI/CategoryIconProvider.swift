import UIKit

/// Category artwork lookup. Uses the bundled illustration when present (downscaled to the requested size,
/// so callers without size constraints never show it at full resolution); otherwise draws a quiet
/// placeholder (thin circle + one glyph). Images are cached per category and size, so scrolling never
/// re-decodes or re-renders them, and food records never carry image data.
enum CategoryIconProvider {
    private static let cache = NSCache<NSString, UIImage>()

    static func image(for categoryID: String, size: CGFloat) -> UIImage {
        let category = FoodCategoryCatalog.category(id: categoryID)
        let side = max(8, size.rounded())
        let key = "\(category.id)@\(side)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let image = UIImage(named: category.assetName).map { render($0, side: side) } ?? renderPlaceholder(category, side: side)
        cache.setObject(image, forKey: key)
        return image
    }

    /// Aspect-fits the illustration into a square of `side` points (rendered at screen scale).
    private static func render(_ asset: UIImage, side: CGFloat) -> UIImage {
        let bounds = CGRect(x: 0, y: 0, width: side, height: side)
        let fit = FridgeLayoutEngine.aspectFitRect(contentSize: asset.size, in: bounds)
        return UIGraphicsImageRenderer(bounds: bounds).image { _ in asset.draw(in: fit) }
    }

    private static func renderPlaceholder(_ category: FoodCategory, side: CGFloat) -> UIImage {
        let bounds = CGRect(x: 0, y: 0, width: side, height: side)
        return UIGraphicsImageRenderer(bounds: bounds).image { _ in
            let circle = UIBezierPath(ovalIn: bounds.insetBy(dx: 0.75, dy: 0.75))
            Theme.Color.interior.setFill()
            circle.fill()
            Theme.Color.divider.setStroke()
            circle.lineWidth = 1
            circle.stroke()

            let font = UIFont.systemFont(ofSize: side * 0.5, weight: .medium)
            let text = category.placeholderGlyph as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Theme.Color.textSecondary]
            let textSize = text.size(withAttributes: attributes)
            text.draw(at: CGPoint(x: bounds.midX - textSize.width / 2, y: bounds.midY - textSize.height / 2),
                      withAttributes: attributes)
        }
    }
}
