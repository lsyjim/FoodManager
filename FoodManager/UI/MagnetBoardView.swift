import UIKit

/// Draws a fridge's magnets over the closed-door artwork. Lay it out with exactly the artwork's bounds; the
/// door surface inside is computed from the template (aspect-fit, minus the artwork's padding), so magnets sit
/// in the same place on every screen size.
///
/// Display mode ignores touches entirely (taps fall through to the door). Edit mode adds tap / pan / pinch /
/// rotation gestures and reports them; the owner applies them to its draft and calls `update(_:)`.
final class MagnetBoardView: UIView, UIGestureRecognizerDelegate {
    enum Mode { case display, edit }

    let template: FridgeTemplate
    private let library: MagnetLibrary
    private(set) var mode: Mode = .display
    private(set) var magnets: [FridgeMagnet] = []
    private var views: [UUID: MagnetView] = [:]
    private(set) var selectedID: UUID?
    /// Magnet under the finger when the current touch sequence started (a drag grabs this one).
    private var touchDownMagnetID: UUID?

    var onSelect: ((UUID?) -> Void)?
    /// Normalized door deltas.
    var onMove: ((UUID, Double, Double) -> Void)?
    var onScale: ((UUID, Double) -> Void)?
    var onRotate: ((UUID, Double) -> Void)?
    var onGestureEnded: (() -> Void)?
    /// Tap on the already selected magnet: show its next style.
    var onCycleStyle: ((UUID) -> Void)?
    /// Accessibility actions on a magnet (VoiceOver users can't pinch or rotate precisely).
    var onAccessibilityAction: ((UUID, MagnetAccessibilityAction) -> Void)?

    private lazy var tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
    private lazy var pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan))
    private lazy var pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch))
    private lazy var rotation = UIRotationGestureRecognizer(target: self, action: #selector(handleRotation))

    init(template: FridgeTemplate, library: MagnetLibrary) {
        self.template = template
        self.library = library
        super.init(frame: .zero)
        backgroundColor = .clear
        clipsToBounds = true
        isUserInteractionEnabled = false
        accessibilityIdentifier = "magnets.board"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var doorRect: CGRect { MagnetGeometry.doorRect(template: template, in: bounds) }

    func setMode(_ mode: Mode) {
        self.mode = mode
        isUserInteractionEnabled = mode == .edit
        for gesture in [tap, pan, pinch, rotation] as [UIGestureRecognizer] {
            if mode == .edit {
                gesture.delegate = self
                addGestureRecognizer(gesture)
            } else {
                removeGestureRecognizer(gesture)
            }
        }
        if mode == .display { select(nil, notify: false) }
        for view in views.values { view.isEditing = mode == .edit }
    }

    /// Replaces all magnets (bottom layer first). Image views are reused by ID, so images aren't re-decoded.
    func render(_ magnets: [FridgeMagnet]) {
        self.magnets = magnets
        let ids = Set(magnets.map(\.id))
        for (id, view) in views where !ids.contains(id) {
            view.removeFromSuperview()
            views[id] = nil
        }
        for magnet in magnets {
            let view = views[magnet.id] ?? makeView(for: magnet)
            views[magnet.id] = view
            bringSubviewToFront(view) // order = array order
            view.magnet = magnet
            view.style = magnet.style
        }
        if let selectedID, !ids.contains(selectedID) { select(nil, notify: true) }
        accessibilityElements = magnets.reversed().compactMap { views[$0.id] }
        setNeedsLayout()
    }

    /// Updates one magnet's geometry only (used on every gesture step: no image work, no layout pass).
    func update(_ magnet: FridgeMagnet) {
        guard let index = magnets.firstIndex(where: { $0.id == magnet.id }), let view = views[magnet.id] else { return }
        magnets[index] = magnet
        view.magnet = magnet
        view.style = magnet.style
        place(view, magnet, door: doorRect)
    }

    func select(_ id: UUID?, notify: Bool = true) {
        selectedID = id
        for (key, view) in views { view.isSelected = key == id }
        if notify { onSelect?(id) }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let door = doorRect
        for magnet in magnets { if let view = views[magnet.id] { place(view, magnet, door: door) } }
    }

    private func place(_ view: MagnetView, _ magnet: FridgeMagnet, door: CGRect) {
        guard door.width > 0 else { return }
        view.transform = .identity
        view.bounds = CGRect(origin: .zero, size: MagnetGeometry.size(of: magnet, in: door))
        view.center = MagnetGeometry.center(of: magnet, in: door)
        view.transform = CGAffineTransform(rotationAngle: magnet.rotation)
    }

    private func makeView(for magnet: FridgeMagnet) -> MagnetView {
        let view = MagnetView(image: library.image(for: magnet), name: Self.name(of: magnet), style: magnet.style)
        view.isEditing = mode == .edit
        view.onAccessibilityAction = { [weak self] action in self?.onAccessibilityAction?(magnet.id, action) }
        addSubview(view)
        return view
    }

    static func name(of magnet: FridgeMagnet) -> String {
        switch magnet.source {
        case .builtIn: return "內建磁鐵"
        case .photo: return "照片磁鐵"
        }
    }

    // MARK: Gestures

    /// Top-most magnet under the point, respecting each magnet's rotation.
    func magnetID(at point: CGPoint) -> UUID? {
        for magnet in magnets.reversed() {
            guard let view = views[magnet.id] else { continue }
            if view.point(inside: view.convert(point, from: self), with: nil) { return magnet.id }
        }
        return nil
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        let id = magnetID(at: gesture.location(in: self))
        if let id, id == selectedID {
            onCycleStyle?(id)
        } else {
            select(id)
        }
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        // Grabbing another magnet selects it, so one drag both picks and moves it.
        if gesture.state == .began, let id = touchDownMagnetID, id != selectedID { select(id) }
        guard let id = selectedID else { return }
        let door = doorRect
        guard door.width > 0, door.height > 0 else { return }
        let t = gesture.translation(in: self)
        gesture.setTranslation(.zero, in: self)
        if gesture.state == .changed { onMove?(id, Double(t.x / door.width), Double(t.y / door.height)) }
        if [.ended, .cancelled, .failed].contains(gesture.state) { onGestureEnded?() }
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        if gesture.state == .began, selectedID == nil, let id = magnetID(at: gesture.location(in: self)) { select(id) }
        guard let id = selectedID else { return }
        if gesture.state == .changed { onScale?(id, Double(gesture.scale)) }
        gesture.scale = 1
        if [.ended, .cancelled, .failed].contains(gesture.state) { onGestureEnded?() }
    }

    @objc private func handleRotation(_ gesture: UIRotationGestureRecognizer) {
        if gesture.state == .began, selectedID == nil, let id = magnetID(at: gesture.location(in: self)) { select(id) }
        guard let id = selectedID else { return }
        if gesture.state == .changed { onRotate?(id, Double(gesture.rotation)) }
        gesture.rotation = 0
        if [.ended, .cancelled, .failed].contains(gesture.state) { onGestureEnded?() }
    }

    /// Pan, pinch and rotation work together (move while resizing / turning); a tap never competes with them.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        let continuous: [UIGestureRecognizer] = [pan, pinch, rotation]
        return continuous.contains(gestureRecognizer) && continuous.contains(other)
    }

    /// Remembers where the finger first landed (the pan's own location is already past its movement threshold).
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if gestureRecognizer === pan { touchDownMagnetID = magnetID(at: touch.location(in: self)) }
        return true
    }

    /// One-finger drags only start on a magnet or when one is selected, so empty-door swipes do nothing.
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === pan { return selectedID != nil || touchDownMagnetID != nil }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }
}

enum MagnetAccessibilityAction: CaseIterable {
    case nextStyle, moveUp, moveDown, moveLeft, moveRight, enlarge, shrink, rotateRight, rotateLeft

    var title: String {
        switch self {
        case .nextStyle: return "換造型"
        case .moveUp: return "往上移"
        case .moveDown: return "往下移"
        case .moveLeft: return "往左移"
        case .moveRight: return "往右移"
        case .enlarge: return "放大"
        case .shrink: return "縮小"
        case .rotateRight: return "向右轉"
        case .rotateLeft: return "向左轉"
        }
    }
}

/// One magnet: the artwork with a soft "stuck on" shadow, plus a dashed selection frame in edit mode.
/// One magnet: its picture presented in a `MagnetStyle`, a soft "stuck on" shadow, and a dashed selection
/// frame in edit mode. Geometry changes only move / scale / rotate this view; the image is never re-decoded.
final class MagnetView: UIView {
    static let paper = UIColor(red: 0.985, green: 0.975, blue: 0.95, alpha: 1)

    /// Carries the shadow (follows the outline via `shadowPath`, or the picture's alpha for 原始形狀).
    private let content = UIView()
    /// Clipped to the style's outline.
    private let clip = UIView()
    private let paperLayer = CAShapeLayer()
    private let imageView = UIImageView()
    private let maskLayer = CAShapeLayer()
    private let selectionLayer = CAShapeLayer()
    private let hasImage: Bool
    var magnet: FridgeMagnet?
    var onAccessibilityAction: ((MagnetAccessibilityAction) -> Void)?

    var style: MagnetStyle {
        didSet { if style != oldValue { setNeedsLayout() } }
    }

    var isSelected = false { didSet { updateSelection() } }
    var isEditing = false {
        didSet {
            updateSelection()
            accessibilityCustomActions = isEditing ? MagnetAccessibilityAction.allCases.map { action in
                UIAccessibilityCustomAction(name: action.title) { [weak self] _ in
                    self?.onAccessibilityAction?(action)
                    return true
                }
            } : nil
        }
    }

    init(image: UIImage?, name: String, style: MagnetStyle) {
        self.style = style
        hasImage = image != nil
        super.init(frame: .zero)
        isUserInteractionEnabled = false // the board does all hit-testing
        for view in [content, clip] {
            view.frame = bounds
            view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        }
        addSubview(content)
        content.addSubview(clip)
        clip.layer.addSublayer(paperLayer)
        // Artwork from a newer build or a missing photo: keep the magnet visible and editable on paper.
        imageView.image = image
        imageView.clipsToBounds = true
        clip.addSubview(imageView)
        content.layer.shadowColor = Theme.Color.stroke.cgColor
        content.layer.shadowOpacity = 0.22
        content.layer.shadowRadius = 2.5
        content.layer.shadowOffset = CGSize(width: 0, height: 1.5)
        selectionLayer.fillColor = UIColor.clear.cgColor
        selectionLayer.strokeColor = Theme.Color.stroke.cgColor
        selectionLayer.lineWidth = 1.5
        selectionLayer.lineDashPattern = [5, 4]
        selectionLayer.isHidden = true
        layer.addSublayer(selectionLayer)
        isAccessibilityElement = true
        accessibilityLabel = name
        accessibilityIdentifier = "magnet.\(name)"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let shape = MagnetShape(style: style, size: bounds.size)
        paperLayer.path = shape.outline?.cgPath
        paperLayer.fillColor = (style == .original && hasImage ? UIColor.clear : Self.paper).cgColor
        paperLayer.strokeColor = style == .original || style == .circle || style == .star
            ? UIColor.clear.cgColor : Theme.Color.divider.withAlphaComponent(0.6).cgColor
        paperLayer.lineWidth = 0.5
        imageView.frame = shape.imageRect
        imageView.contentMode = style == .original ? .scaleAspectFit : .scaleAspectFill
        imageView.layer.cornerRadius = style == .roundedFrame ? min(bounds.width, bounds.height) * 0.04 : 0
        // 原始形狀's shadow follows the picture's alpha: rasterize so moving / rotating doesn't recompute it.
        content.layer.shouldRasterize = style == .original && hasImage
        content.layer.rasterizationScale = traitCollection.displayScale
        if let outline = shape.outline, style != .original {
            maskLayer.path = outline.cgPath
            clip.layer.mask = maskLayer
            content.layer.shadowPath = outline.cgPath
        } else {
            clip.layer.mask = nil
            content.layer.shadowPath = hasImage ? nil : shape.outline?.cgPath
        }
        selectionLayer.path = UIBezierPath(roundedRect: bounds.insetBy(dx: -5, dy: -5), cornerRadius: 8).cgPath
        CATransaction.commit()
    }

    private func updateSelection() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        selectionLayer.isHidden = !(isEditing && isSelected)
        CATransaction.commit()
        accessibilityTraits = isEditing && isSelected ? [.selected] : []
        accessibilityValue = isEditing ? style.title : nil
    }
}

/// Outline and picture area of a style at a given size.
struct MagnetShape {
    /// nil for 原始形狀 (the picture's own alpha is the shape).
    let outline: UIBezierPath?
    let imageRect: CGRect

    init(style: MagnetStyle, size: CGSize) {
        let bounds = CGRect(origin: .zero, size: size)
        let layout = MagnetStyleLayout(style)
        let w = size.width
        let inner = CGRect(x: w * layout.side, y: w * layout.top,
                           width: max(0, w - 2 * w * layout.side),
                           height: max(0, size.height - w * (layout.top + layout.bottom)))
        switch style {
        case .original:
            outline = UIBezierPath(roundedRect: bounds, cornerRadius: min(w, size.height) * 0.06)
            imageRect = bounds
        case .polaroid, .squareFrame:
            outline = UIBezierPath(rect: bounds)
            imageRect = inner
        case .roundedFrame:
            outline = UIBezierPath(roundedRect: bounds, cornerRadius: min(w, size.height) * 0.1)
            imageRect = inner
        case .stamp:
            outline = Self.scallopedRect(in: bounds)
            imageRect = inner
        case .circle:
            outline = UIBezierPath(ovalIn: bounds)
            imageRect = bounds
        case .star:
            outline = Self.star(in: bounds)
            imageRect = bounds
        }
    }

    /// Rectangle whose edges are rows of small half-circles (a wavy stamp edge), kept inside `rect`.
    static func scallopedRect(in rect: CGRect) -> UIBezierPath {
        let target = max(2, min(rect.width, rect.height) * 0.035)
        let body = rect.insetBy(dx: target, dy: target)
        let path = UIBezierPath()
        guard body.width > 0, body.height > 0 else { return UIBezierPath(rect: rect) }
        let nx = max(3, Int((body.width / (2 * target)).rounded()))
        let ny = max(3, Int((body.height / (2 * target)).rounded()))
        let rx = body.width / CGFloat(2 * nx)
        let ry = body.height / CGFloat(2 * ny)
        path.move(to: CGPoint(x: body.minX, y: body.minY))
        for i in 0..<nx { // top, left → right, bumps up
            path.addArc(withCenter: CGPoint(x: body.minX + CGFloat(2 * i + 1) * rx, y: body.minY), radius: rx,
                        startAngle: .pi, endAngle: 0, clockwise: true)
        }
        for i in 0..<ny { // right, top → bottom, bumps right
            path.addArc(withCenter: CGPoint(x: body.maxX, y: body.minY + CGFloat(2 * i + 1) * ry), radius: ry,
                        startAngle: -.pi / 2, endAngle: .pi / 2, clockwise: true)
        }
        for i in 0..<nx { // bottom, right → left, bumps down
            path.addArc(withCenter: CGPoint(x: body.maxX - CGFloat(2 * i + 1) * rx, y: body.maxY), radius: rx,
                        startAngle: 0, endAngle: .pi, clockwise: true)
        }
        for i in 0..<ny { // left, bottom → top, bumps left
            path.addArc(withCenter: CGPoint(x: body.minX, y: body.maxY - CGFloat(2 * i + 1) * ry), radius: ry,
                        startAngle: .pi / 2, endAngle: 3 * .pi / 2, clockwise: true)
        }
        path.close()
        return path
    }

    /// Chubby five-pointed star stretched so its points touch every edge of `rect`.
    static func star(in rect: CGRect) -> UIBezierPath {
        let path = UIBezierPath()
        for i in 0..<10 {
            let radius: CGFloat = i.isMultiple(of: 2) ? 1 : 0.52
            let angle = -CGFloat.pi / 2 + CGFloat(i) * .pi / 5
            let point = CGPoint(x: radius * cos(angle), y: radius * sin(angle))
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.close()
        let box = path.bounds
        guard box.width > 0, box.height > 0, rect.width > 0, rect.height > 0 else { return UIBezierPath(rect: rect) }
        path.apply(CGAffineTransform(translationX: -box.minX, y: -box.minY))
        path.apply(CGAffineTransform(scaleX: rect.width / box.width, y: rect.height / box.height))
        path.apply(CGAffineTransform(translationX: rect.minX, y: rect.minY))
        return path
    }
}
