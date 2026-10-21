import UIKit

enum Theme {
    enum Color {
        static let background = UIColor(hex: 0xF3F1ED)
        static let fridgeBody = UIColor(hex: 0xE7E5E0)
        static let interior = UIColor(hex: 0xFAF9F6)
        static let textPrimary = UIColor(hex: 0x383733)
        static let textSecondary = UIColor(hex: 0x827F79)
        static let stroke = UIColor(hex: 0x55514B)
        static let divider = UIColor(hex: 0xB6B2AA)
        static let refrigeratedIndicator = UIColor(hex: 0xB6B2AA)
        static let frozenIndicator = UIColor(hex: 0xA8C9D1)
        static let destructive = UIColor(hex: 0xA0473A)

        /// Small accent identifying a compartment's storage classification; nil means no indicator.
        static func indicator(for storage: StorageType) -> UIColor? {
            switch storage {
            case .refrigerated: return refrigeratedIndicator
            case .frozen: return frozenIndicator
            case .unspecified: return nil
            }
        }
    }

    enum Font {
        static let title = UIFont.systemFont(ofSize: 22, weight: .semibold)
        static let body = UIFont.systemFont(ofSize: 15, weight: .regular)
        static let caption = UIFont.systemFont(ofSize: 12, weight: .regular)
        static let compartment = UIFont.systemFont(ofSize: 11, weight: .medium)
        static let metric = UIFont.monospacedDigitSystemFont(ofSize: 22, weight: .light)
        static let button = UIFont.systemFont(ofSize: 15, weight: .medium)
    }

    enum Metric {
        static let gutter: CGFloat = 20
        static let strokeWidth: CGFloat = 1
        static let minTouchTarget: CGFloat = 44
        /// Side inset of the open fridge; kept small because the artwork is width-limited in portrait.
        static let openFridgeInset: CGFloat = 6
    }

    enum Animation {
        static let doorDuration: TimeInterval = 0.4
    }
}

extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: alpha)
    }
}

extension UIButton {
    /// Quiet, outlined text button used across the app.
    static func sketchButton(title: String, systemImage: String? = nil, filled: Bool = false) -> UIButton {
        var config = filled ? UIButton.Configuration.filled() : UIButton.Configuration.plain()
        config.title = title
        config.baseForegroundColor = filled ? Theme.Color.interior : Theme.Color.textPrimary
        config.baseBackgroundColor = Theme.Color.stroke
        config.cornerStyle = .capsule
        config.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 14)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attrs in
            var attrs = attrs
            attrs.font = Theme.Font.button
            return attrs
        }
        if let systemImage {
            config.image = UIImage(systemName: systemImage,
                                   withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .medium))
            config.imagePadding = 4
        }
        let button = UIButton(configuration: config)
        if !filled {
            button.layer.borderColor = Theme.Color.divider.cgColor
            button.layer.borderWidth = Theme.Metric.strokeWidth
            button.layer.cornerRadius = 18
        }
        button.translatesAutoresizingMaskIntoConstraints = false
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 36).isActive = true
        return button
    }
}
