import UIKit

/// Compact card on the fridge home (每週餐桌 / 購物清單): icon, title and today's count, one tap to open.
final class HomeShortcutCard: UIControl {
    private let icon = UIImageView()
    private let titleLabel = UILabel()
    private let valueLabel = UILabel()

    init(title: String, systemImage: String, identifier: String) {
        super.init(frame: .zero)
        accessibilityIdentifier = identifier
        isAccessibilityElement = true
        accessibilityTraits = .button
        backgroundColor = Theme.Color.interior
        layer.cornerRadius = 14
        layer.borderWidth = 1
        layer.borderColor = Theme.Color.fridgeBody.cgColor

        icon.image = UIImage(systemName: systemImage)
        icon.tintColor = Theme.Color.stroke
        icon.contentMode = .scaleAspectFit
        icon.setContentHuggingPriority(.required, for: .horizontal)
        titleLabel.text = title
        titleLabel.font = UIFont.preferredFont(forTextStyle: .subheadline).withWeight(.semibold)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = Theme.Color.textPrimary
        valueLabel.font = UIFont.preferredFont(forTextStyle: .caption1)
        valueLabel.adjustsFontForContentSizeCategory = true
        valueLabel.textColor = Theme.Color.textSecondary
        for label in [titleLabel, valueLabel] {
            label.adjustsFontSizeToFitWidth = true
            label.minimumScaleFactor = 0.8
        }
        let texts = UIStackView(arrangedSubviews: [titleLabel, valueLabel])
        texts.axis = .vertical
        texts.spacing = 1
        let row = UIStackView(arrangedSubviews: [icon, texts])
        row.spacing = 10
        row.alignment = .center
        row.isUserInteractionEnabled = false
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 22),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            heightAnchor.constraint(greaterThanOrEqualToConstant: Theme.Metric.minTouchTarget)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setValue(_ text: String) {
        valueLabel.text = text
        accessibilityLabel = "\(titleLabel.text ?? "")，\(text)"
    }

    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.6 : 1 }
    }
}

/// Counts shown on the home cards.
enum HomeShortcutCounts {
    /// Meal slots (早餐/午餐/晚餐) with at least one dish today.
    static func mealsPlannedToday(_ dishes: [PlannedDish], today: DayKey) -> Int {
        Set(dishes.filter { $0.day == today }.map(\.meal)).count
    }

    static func mealText(_ count: Int) -> String { count == 0 ? "今天還沒安排" : "今天 \(count) 餐已規劃" }
    static func shoppingText(_ pending: Int) -> String { pending == 0 ? "清單是空的" : "\(pending) 項待購買" }
}
