import UIKit
import os

/// Loads fridge artwork by asset key, falling back to temporary programmatic line art when an asset is missing.
/// The fallback is drawn from the template geometry so overlays still line up.
enum FridgeArtwork {
    private static let logger = Logger(subsystem: "FoodManager.HowCode", category: "Artwork")

    static func closedImage(for template: FridgeTemplate) -> UIImage {
        if let image = UIImage(named: template.closedImageKey) { return image }
        logger.error("Missing asset \(template.closedImageKey); using fallback line art")
        return renderClosed(size: template.closedImageSize)
    }

    static func openImage(for template: FridgeTemplate) -> UIImage {
        if let image = UIImage(named: template.openImageKey) { return image }
        logger.error("Missing asset \(template.openImageKey); using fallback line art")
        return renderOpen(template: template)
    }

    private static func renderClosed(size: CGSize) -> UIImage {
        UIGraphicsImageRenderer(size: size).image { _ in
            let body = CGRect(origin: .zero, size: size).insetBy(dx: 12, dy: 12)
            stroke(UIBezierPath(roundedRect: body, cornerRadius: 24), fill: Theme.Color.fridgeBody)
            let handle = CGRect(x: body.minX + body.width * 0.12, y: body.minY + body.height * 0.22,
                                width: 14, height: body.height * 0.32)
            stroke(UIBezierPath(roundedRect: handle, cornerRadius: 7), fill: Theme.Color.divider)
        }
    }

    private static func renderOpen(template: FridgeTemplate) -> UIImage {
        let size = template.openImageSize
        let canvas = CGRect(origin: .zero, size: size)
        return UIGraphicsImageRenderer(size: size).image { _ in
            for zone in ZoneID.allCases {
                let inner = FridgeLayoutEngine.rect(for: template.editableRect(for: zone), in: canvas)
                stroke(UIBezierPath(roundedRect: inner.insetBy(dx: -28, dy: -28), cornerRadius: 20), fill: Theme.Color.fridgeBody)
                stroke(UIBezierPath(roundedRect: inner, cornerRadius: 6), fill: Theme.Color.interior)
            }
        }
    }

    private static func stroke(_ path: UIBezierPath, fill: UIColor) {
        fill.setFill()
        path.fill()
        Theme.Color.stroke.setStroke()
        path.lineWidth = 2
        path.stroke()
    }
}
