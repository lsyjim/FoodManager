import UIKit

/// One independently editable zone (cabinet interior or door interior). Lays out its compartments
/// by converting their normalized frames into this view's bounds; it knows nothing about the artwork.
class FridgeZoneView: UIView {
    let zone: ZoneID
    var onSelectCompartment: ((UUID) -> Void)?
    var summaryProvider: (UUID) -> CompartmentContentSummary = { _ in .empty }

    private var compartmentViews: [UUID: CompartmentView] = [:]
    private var compartments: [Compartment] = []
    private var isEditingLayout = false
    private var selectedID: UUID?
    private let emptyLabel = UILabel()
    private var hitOutset: CGFloat { FridgeLayoutEngine.hitOutset(zoneHeight: bounds.height) }

    init(zone: ZoneID) {
        self.zone = zone
        super.init(frame: .zero)
        emptyLabel.text = "尚無隔層"
        emptyLabel.font = Theme.Font.caption
        emptyLabel.textColor = Theme.Color.textSecondary
        emptyLabel.textAlignment = .center
        addSubview(emptyLabel)
        accessibilityLabel = zone.displayName
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(compartments: [Compartment], editing: Bool, selectedID: UUID?, animated: Bool) {
        self.compartments = compartments
        isEditingLayout = editing
        self.selectedID = selectedID
        emptyLabel.isHidden = !compartments.isEmpty

        let ids = Set(compartments.map(\.id))
        for (id, view) in compartmentViews where !ids.contains(id) {
            view.removeFromSuperview()
            compartmentViews[id] = nil
        }
        for compartment in compartments {
            let view = compartmentViews[compartment.id] ?? makeView(for: compartment)
            view.apply(compartment, summary: summaryProvider(compartment.id))
            view.setEditing(editing, selected: compartment.id == selectedID)
        }

        if animated {
            UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseInOut, .beginFromCurrentState]) {
                self.layoutCompartments()
            }
        } else {
            setNeedsLayout()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        emptyLabel.frame = bounds
        layoutCompartments()
    }

    /// Lets the first/last compartment's outset band (above/below the zone) still reach it.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.insetBy(dx: 0, dy: -hitOutset).contains(point)
    }

    private func layoutCompartments() {
        for compartment in compartments {
            compartmentViews[compartment.id]?.hitOutset = hitOutset
            compartmentViews[compartment.id]?.frame =
                FridgeLayoutEngine.rect(for: compartment.normalizedFrame, in: bounds)
            compartmentViews[compartment.id]?.layoutIfNeeded()
        }
    }

    private func makeView(for compartment: Compartment) -> CompartmentView {
        let view = CompartmentView(compartment: compartment)
        view.onTap = { [weak self] id in self?.onSelectCompartment?(id) }
        // New views start at their final frame so they don't fly in from the origin.
        view.frame = FridgeLayoutEngine.rect(for: compartment.normalizedFrame, in: bounds)
        addSubview(view)
        compartmentViews[compartment.id] = view
        return view
    }
}

final class FridgeCabinetView: FridgeZoneView {
    init() { super.init(zone: .cabinet) }
}

final class FridgeDoorView: FridgeZoneView {
    init() { super.init(zone: .door) }
}
