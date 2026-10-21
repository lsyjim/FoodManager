import UIKit

/// One programmatic compartment overlay: type decoration, storage indicator, name, a fixed item-count
/// badge at the top-right and a horizontally scrolling row with one icon per active food record.
///
/// Normal mode draws only the type decoration (shelf edge / drawer handle / door lip) so it doesn't
/// fight the illustration's own lines. Edit mode adds a single dashed outline; selection makes it solid.
///
/// Touch routing (see `hitTest`): a swipe on a scrollable icon row scrolls it; a tap anywhere reports `onTap`.
/// In edit mode the icon row neither scrolls nor intercepts touches, so layout selection is unchanged.
final class CompartmentView: UIView, UICollectionViewDataSource {
    var onTap: ((UUID) -> Void)?
    /// Extra vertical hit area above and below (half the inter-compartment gap), so small compartments
    /// still get ≥ 44pt targets without ever overlapping a neighbour's target.
    var hitOutset: CGFloat = 0

    private(set) var compartment: Compartment
    private(set) var summary: CompartmentContentSummary = .empty

    private let button = UIButton(type: .custom)
    private let border = SketchShapeView()
    private let decoration = SketchShapeView()
    private let storageDot = UIView()
    private let nameLabel = UILabel()
    let countLabel = UILabel()
    let iconCollection: UICollectionView
    private let iconLayout = UICollectionViewFlowLayout()
    private var isEditingLayout = false
    private var isSelectedForEdit = false
    private lazy var dotWidth = storageDot.widthAnchor.constraint(equalToConstant: Self.dotSize)
    private lazy var dotSpacing = nameLabel.leadingAnchor.constraint(equalTo: storageDot.trailingAnchor, constant: 4)

    private static let dotSize: CGFloat = 6

    init(compartment: Compartment) {
        self.compartment = compartment
        iconLayout.scrollDirection = .horizontal
        iconLayout.minimumLineSpacing = CompartmentIconMetrics.spacing
        iconLayout.minimumInteritemSpacing = CompartmentIconMetrics.spacing
        iconCollection = UICollectionView(frame: .zero, collectionViewLayout: iconLayout)
        super.init(frame: .zero)
        setUp()
        apply(compartment)
        setEditing(false, selected: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func apply(_ compartment: Compartment, summary: CompartmentContentSummary = .empty) {
        self.compartment = compartment
        nameLabel.text = compartment.name
        countLabel.text = "\(summary.itemCount)"
        border.seed = compartment.id.sketchSeed
        decoration.seed = compartment.id.sketchSeed &+ 7
        decoration.pathProvider = Self.decorationPath(for: compartment.type)
        let indicator = Theme.Color.indicator(for: compartment.storageType)
        storageDot.backgroundColor = indicator
        storageDot.isHidden = indicator == nil
        dotWidth.constant = indicator == nil ? 0 : Self.dotSize
        dotSpacing.constant = indicator == nil ? 0 : 4
        // Frozen compartments tint their decoration line with the gray-blue accent; everything else stays warm gray.
        decoration.strokeColor = compartment.storageType == .frozen ? Theme.Color.frozenIndicator : Theme.Color.divider
        if summary != self.summary {
            self.summary = summary
            iconCollection.reloadData()
            setNeedsLayout()
        }
        updateAccessibility()
    }

    func setEditing(_ editing: Bool, selected: Bool) {
        isEditingLayout = editing
        isSelectedForEdit = selected
        border.isHidden = !editing
        border.isDashed = !selected
        border.lineWidth = selected ? 2 : Theme.Metric.strokeWidth
        border.strokeColor = selected ? Theme.Color.textPrimary : Theme.Color.stroke.withAlphaComponent(0.55)
        backgroundColor = selected ? Theme.Color.fridgeBody.withAlphaComponent(0.5) : .clear
        iconCollection.isScrollEnabled = !editing
        updateAccessibility()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        countLabel.layer.cornerRadius = countLabel.bounds.height / 2
        if let metrics = CompartmentIconMetrics(bounds: bounds) {
            iconCollection.isHidden = summary.icons.isEmpty
            if iconCollection.frame != metrics.rowFrame { iconCollection.frame = metrics.rowFrame }
            if iconLayout.itemSize.width != metrics.iconSize {
                iconLayout.itemSize = CGSize(width: metrics.iconSize, height: metrics.iconSize)
                iconLayout.invalidateLayout()
            }
        } else {
            // Too small for legible icons: keep the name and count readable instead.
            iconCollection.isHidden = true
        }
    }

    /// Whether the icon row currently has more icons than fit, i.e. a swipe would scroll it.
    var isIconRowScrollable: Bool {
        !iconCollection.isHidden && iconCollection.contentSize.width > iconCollection.bounds.width + 0.5
    }

    // MARK: - Hit testing

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.insetBy(dx: 0, dy: -hitOutset).contains(point)
    }

    /// Swipes on a scrollable icon row go to the collection view (its tap recognizer still reports taps);
    /// everything else — including the outset band and all of edit mode — goes to the button.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard isUserInteractionEnabled, !isHidden, alpha > 0.01, self.point(inside: point, with: event) else { return nil }
        if !isEditingLayout, isIconRowScrollable, iconCollection.frame.contains(point) {
            return iconCollection
        }
        return button
    }

    // MARK: - UICollectionViewDataSource

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        summary.icons.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: FoodIconCell.reuseID, for: indexPath) as! FoodIconCell
        cell.configure(categoryID: summary.icons[indexPath.item].categoryID, size: iconLayout.itemSize.width)
        return cell
    }

    // MARK: - Setup

    private func setUp() {
        layer.cornerRadius = 3

        storageDot.layer.cornerRadius = Self.dotSize / 2
        storageDot.isAccessibilityElement = false

        nameLabel.font = Theme.Font.compartment
        nameLabel.textColor = Theme.Color.textPrimary
        nameLabel.adjustsFontSizeToFitWidth = true
        nameLabel.minimumScaleFactor = 0.8
        nameLabel.lineBreakMode = .byTruncatingTail

        countLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
        countLabel.textColor = Theme.Color.textSecondary
        countLabel.textAlignment = .center
        countLabel.layer.borderColor = Theme.Color.divider.cgColor
        countLabel.layer.borderWidth = Theme.Metric.strokeWidth
        countLabel.backgroundColor = Theme.Color.interior
        countLabel.clipsToBounds = true

        iconCollection.backgroundColor = .clear
        iconCollection.showsHorizontalScrollIndicator = false
        iconCollection.showsVerticalScrollIndicator = false
        iconCollection.alwaysBounceVertical = false
        iconCollection.clipsToBounds = true
        iconCollection.allowsSelection = false
        iconCollection.dataSource = self
        iconCollection.register(FoodIconCell.self, forCellWithReuseIdentifier: FoodIconCell.reuseID)
        iconCollection.accessibilityElementsHidden = true // the button announces the count; the list sheet has details
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
        iconCollection.addGestureRecognizer(tap)

        button.addTarget(self, action: #selector(tapped), for: .touchUpInside)

        addSubview(iconCollection) // frame-based (see layoutSubviews)
        for view in [border, decoration, storageDot, nameLabel, countLabel, button] as [UIView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        // The count badge sits above the scrolling row so it stays fixed and readable.
        bringSubviewToFront(countLabel)
        NSLayoutConstraint.activate(
            [border, decoration, button].flatMap { view in
                [view.topAnchor.constraint(equalTo: topAnchor),
                 view.leadingAnchor.constraint(equalTo: leadingAnchor),
                 view.trailingAnchor.constraint(equalTo: trailingAnchor),
                 view.bottomAnchor.constraint(equalTo: bottomAnchor)]
            } + [
                storageDot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
                storageDot.centerYAnchor.constraint(equalTo: nameLabel.centerYAnchor),
                dotWidth,
                storageDot.heightAnchor.constraint(equalToConstant: Self.dotSize),

                nameLabel.topAnchor.constraint(equalTo: topAnchor, constant: 5),
                dotSpacing,
                nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: countLabel.leadingAnchor, constant: -4),

                countLabel.topAnchor.constraint(equalTo: topAnchor, constant: 4),
                countLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
                countLabel.heightAnchor.constraint(equalToConstant: 16),
                countLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 16),
            ])
        countLabel.setContentHuggingPriority(.required, for: .horizontal)
        countLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    private func updateAccessibility() {
        let storage = compartment.storageType == .unspecified ? "" : "\(compartment.storageType.displayName)"
        button.accessibilityLabel = "\(storage)\(compartment.type.displayName)：\(compartment.name)，\(summary.itemCount) 項"
        button.accessibilityHint = isEditingLayout ? "點兩下編輯此隔層" : "點兩下查看食材"
        button.accessibilityTraits = [.button]
        if isSelectedForEdit { button.accessibilityTraits.insert(.selected) }
        button.isAccessibilityElement = true
    }

    @objc private func tapped() {
        onTap?(compartment.id)
    }

    // MARK: - Type decoration

    private static func decorationPath(for type: CompartmentType) -> (CGRect, UInt64) -> UIBezierPath {
        switch type {
        case .shelf:
            // A glass shelf edge a few points above the bottom.
            return { rect, seed in
                var rng = SeededRandom(seed: seed)
                let path = UIBezierPath()
                let y = rect.maxY - 2
                SketchPath.line(from: CGPoint(x: rect.minX + 2, y: y), to: CGPoint(x: rect.maxX - 2, y: y),
                                into: path, rng: &rng)
                return path
            }
        case .drawer:
            // A short pull handle centred near the bottom.
            return { rect, seed in
                var rng = SeededRandom(seed: seed)
                let path = UIBezierPath()
                let width = min(rect.width * 0.28, 60)
                let y = rect.maxY - max(6, rect.height * 0.14)
                SketchPath.line(from: CGPoint(x: rect.midX - width / 2, y: y), to: CGPoint(x: rect.midX + width / 2, y: y),
                                into: path, rng: &rng, wobble: 0.4, overshoot: 0.5)
                return path
            }
        case .doorShelf:
            // The shelf's front lip across the lower third.
            return { rect, seed in
                let lipHeight = max(10, rect.height * 0.3)
                let lip = CGRect(x: rect.minX + 3, y: rect.maxY - lipHeight - 2, width: rect.width - 6, height: lipHeight)
                return SketchPath.rect(lip, seed: seed, wobble: 0.5, overshoot: 1)
            }
        }
    }
}

/// Geometry of the icon row inside a compartment, derived only from the compartment's bounds.
/// Pure so it can be unit-tested for every screen size and user-adjusted height.
struct CompartmentIconMetrics: Equatable {
    static let spacing: CGFloat = 6
    static let horizontalInset: CGFloat = 6
    /// Space reserved at the top for the name and the count badge.
    static let topReserve: CGFloat = 22
    static let bottomInset: CGFloat = 5
    static let maxIconSize: CGFloat = 30
    static let minIconSize: CGFloat = 14

    let iconSize: CGFloat
    let rowFrame: CGRect

    /// nil when the compartment is too short for legible icons.
    init?(bounds: CGRect) {
        let available = bounds.height - Self.topReserve - Self.bottomInset
        let width = bounds.width - 2 * Self.horizontalInset
        guard available >= Self.minIconSize, width > Self.minIconSize else { return nil }
        iconSize = min(Self.maxIconSize, available.rounded(.down))
        rowFrame = CGRect(x: Self.horizontalInset, y: bounds.height - Self.bottomInset - iconSize,
                          width: width, height: iconSize)
    }

    /// Total content width for `count` icons (used to know when the row scrolls).
    func contentWidth(count: Int) -> CGFloat {
        count == 0 ? 0 : CGFloat(count) * iconSize + CGFloat(count - 1) * Self.spacing
    }
}

/// Reusable icon cell; the image comes from the shared category cache, so nothing is decoded per scroll.
final class FoodIconCell: UICollectionViewCell {
    static let reuseID = "FoodIconCell"
    private let imageView = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        imageView.contentMode = .scaleAspectFit
        imageView.frame = contentView.bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        contentView.addSubview(imageView)
        isUserInteractionEnabled = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(categoryID: String, size: CGFloat) {
        imageView.image = CategoryIconProvider.image(for: categoryID, size: size)
    }
}
