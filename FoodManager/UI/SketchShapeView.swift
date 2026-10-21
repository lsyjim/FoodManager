import UIKit

/// Deterministic pseudo-random numbers so a given compartment always gets the same wobble.
struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform value in -magnitude...magnitude.
    mutating func jitter(_ magnitude: CGFloat) -> CGFloat {
        (CGFloat(next() % 10_000) / 10_000 * 2 - 1) * magnitude
    }
}

enum SketchPath {
    /// A hand-drawn rectangle: four slightly bowed strokes that overshoot their corners, like a pen sketch.
    static func rect(_ rect: CGRect, seed: UInt64, wobble: CGFloat = 0.7, overshoot: CGFloat = 1.5) -> UIBezierPath {
        var rng = SeededRandom(seed: seed)
        let corners = [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                       CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]
        let path = UIBezierPath()
        for i in 0..<4 {
            line(from: corners[i], to: corners[(i + 1) % 4], into: path, rng: &rng, wobble: wobble, overshoot: overshoot)
        }
        return path
    }

    static func line(from a: CGPoint, to b: CGPoint, into path: UIBezierPath, rng: inout SeededRandom,
                     wobble: CGFloat = 0.7, overshoot: CGFloat = 1.5) {
        let length = max(hypot(b.x - a.x, b.y - a.y), 1)
        let ux = (b.x - a.x) / length, uy = (b.y - a.y) / length
        let start = CGPoint(x: a.x - ux * rng.jitter(overshoot).magnitude + rng.jitter(wobble),
                            y: a.y - uy * rng.jitter(overshoot).magnitude + rng.jitter(wobble))
        let end = CGPoint(x: b.x + ux * rng.jitter(overshoot).magnitude + rng.jitter(wobble),
                          y: b.y + uy * rng.jitter(overshoot).magnitude + rng.jitter(wobble))
        let bow = rng.jitter(wobble * 1.5)
        let control = CGPoint(x: (start.x + end.x) / 2 - uy * bow, y: (start.y + end.y) / 2 + ux * bow)
        path.move(to: start)
        path.addQuadCurve(to: end, controlPoint: control)
    }
}

/// Non-interactive view that strokes a sketch path, recomputed whenever its bounds change.
final class SketchShapeView: UIView {
    var pathProvider: (CGRect, UInt64) -> UIBezierPath = { SketchPath.rect($0, seed: $1) } {
        didSet { setNeedsLayout() }
    }
    var seed: UInt64 = 1 { didSet { setNeedsLayout() } }
    var strokeColor: UIColor = Theme.Color.stroke { didSet { applyStyle() } }
    var lineWidth: CGFloat = Theme.Metric.strokeWidth { didSet { applyStyle() } }
    var isDashed = false { didSet { applyStyle() } }

    private let shapeLayer = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        shapeLayer.fillColor = UIColor.clear.cgColor
        shapeLayer.lineCap = .round
        shapeLayer.lineJoin = .round
        layer.addSublayer(shapeLayer)
        applyStyle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        shapeLayer.frame = bounds
        shapeLayer.path = pathProvider(bounds.insetBy(dx: 1.5, dy: 1.5), seed).cgPath
    }

    private func applyStyle() {
        shapeLayer.strokeColor = strokeColor.cgColor
        shapeLayer.lineWidth = lineWidth
        shapeLayer.lineDashPattern = isDashed ? [4, 3] : nil
    }
}

extension UUID {
    /// Stable seed for sketch wobble derived from the UUID bytes (hashValue is randomized per launch).
    var sketchSeed: UInt64 {
        withUnsafeBytes(of: uuid) { $0.load(as: UInt64.self) }
    }
}
