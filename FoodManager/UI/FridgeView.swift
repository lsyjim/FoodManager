import UIKit

/// The open, flat (180°) fridge: background artwork plus two geometrically independent zone overlays.
/// Zone frames come only from the template's editable rects mapped onto the aspect-fit image rect.
final class FridgeView: UIView {
    var onSelectCompartment: ((UUID) -> Void)? {
        didSet { zoneViews.forEach { $0.onSelectCompartment = onSelectCompartment } }
    }

    /// Content (food icons + count) for each compartment, supplied by the inventory.
    var summaryProvider: (UUID) -> CompartmentContentSummary = { _ in .empty } {
        didSet { zoneViews.forEach { $0.summaryProvider = summaryProvider } }
    }

    let template: FridgeTemplate
    private let imageView = UIImageView()
    private let cabinetView = FridgeCabinetView()
    private let doorView = FridgeDoorView()
    private let cabinetCaption = UILabel()
    private let doorCaption = UILabel()
    private var zoneViews: [FridgeZoneView] { [cabinetView, doorView] }

    init(template: FridgeTemplate) {
        self.template = template
        super.init(frame: .zero)
        imageView.image = FridgeArtwork.openImage(for: template)
        imageView.contentMode = .scaleToFill // frame is already aspect-fit below
        imageView.isAccessibilityElement = false
        addSubview(imageView)
        zoneViews.forEach(addSubview)

        for (label, zone) in [(cabinetCaption, ZoneID.cabinet), (doorCaption, .door)] {
            label.text = zone.displayName
            label.font = Theme.Font.caption
            label.textColor = Theme.Color.textSecondary
            label.textAlignment = .center
            label.backgroundColor = Theme.Color.interior
            label.layer.cornerRadius = 8
            label.clipsToBounds = true
            label.isHidden = true
            addSubview(label)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Width / height of the artwork, for the owner's aspect-ratio constraint.
    var artworkAspectRatio: CGFloat { template.openImageSize.width / template.openImageSize.height }

    func update(fridge: Fridge, editing: Bool, selectedID: UUID?, animated: Bool) {
        for zoneView in zoneViews {
            zoneView.update(compartments: fridge.compartments(in: zoneView.zone), editing: editing,
                            selectedID: selectedID, animated: animated)
        }
        cabinetCaption.isHidden = !editing
        doorCaption.isHidden = !editing
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let imageFrame = FridgeLayoutEngine.aspectFitRect(contentSize: template.openImageSize, in: bounds)
        imageView.frame = imageFrame
        for zoneView in zoneViews {
            zoneView.frame = FridgeLayoutEngine.zoneFrame(zoneView.zone, template: template, imageFrame: imageFrame)
        }
        for (label, zoneView) in [(cabinetCaption, cabinetView as FridgeZoneView), (doorCaption, doorView)] {
            let width = label.intrinsicContentSize.width + 16
            label.frame = CGRect(x: zoneView.frame.midX - width / 2, y: zoneView.frame.minY - 26, width: width, height: 16)
        }
    }
}

/// The closed fridge artwork as one large tap target that opens the door.
final class ClosedFridgeButton: UIButton {
    let template: FridgeTemplate
    private let artwork = UIImageView()

    init(template: FridgeTemplate) {
        self.template = template
        super.init(frame: .zero)
        artwork.image = FridgeArtwork.closedImage(for: template)
        artwork.contentMode = .scaleAspectFit
        artwork.isUserInteractionEnabled = false
        artwork.translatesAutoresizingMaskIntoConstraints = false
        addSubview(artwork)
        NSLayoutConstraint.activate([
            artwork.topAnchor.constraint(equalTo: topAnchor),
            artwork.leadingAnchor.constraint(equalTo: leadingAnchor),
            artwork.trailingAnchor.constraint(equalTo: trailingAnchor),
            artwork.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        accessibilityLabel = "冰箱（已關門）"
        accessibilityHint = "點兩下打開冰箱"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var artworkAspectRatio: CGFloat { template.closedImageSize.width / template.closedImageSize.height }

    override var isHighlighted: Bool {
        didSet { artwork.alpha = isHighlighted ? 0.85 : 1 }
    }
}
