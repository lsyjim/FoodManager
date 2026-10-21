import UIKit

/// Compact totals beside the closed fridge, switchable between 全部 / 冷藏 / 冷凍.
/// It only renders what its provider returns; Phase 1.1 uses placeholders (dashes), never fake numbers.
final class DashboardView: UIView {
    var provider: DashboardSummaryProviding = PlaceholderDashboardProvider() {
        didSet { reload() }
    }

    /// Tapping 即將到期 / 已過期 / 保存提醒 opens the reminder center with the current storage filter.
    var onSelectReminder: ((ReminderKindFilter, StorageFilter) -> Void)?

    private let stack = UIStackView()
    private var valueLabels: [UILabel] = []
    private var rows: [UIView] = []
    /// Row index → reminder filter (row 0, 食材品項, isn't a reminder).
    private static let reminderKinds: [ReminderKindFilter?] = [nil, .expiringSoon, .expired, .storedTooLong]
    private let filterControl = UISegmentedControl(items: StorageFilter.allCases.map(\.title))
    var filter: StorageFilter {
        StorageFilter.allCases.indices.contains(filterControl.selectedSegmentIndex)
            ? StorageFilter.allCases[filterControl.selectedSegmentIndex] : .all
    }

    private static let titles = ["食材品項", "即將到期", "已過期", "保存提醒"]

    override init(frame: CGRect) {
        super.init(frame: frame)
        stack.axis = .vertical
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        let header = UILabel()
        header.text = "今日概況"
        header.font = Theme.Font.caption
        header.textColor = Theme.Color.textSecondary
        stack.addArrangedSubview(header)
        stack.setCustomSpacing(8, after: header)

        filterControl.selectedSegmentIndex = 0
        filterControl.selectedSegmentTintColor = Theme.Color.interior
        filterControl.backgroundColor = Theme.Color.fridgeBody
        let small = UIFont.systemFont(ofSize: 11, weight: .medium)
        filterControl.setTitleTextAttributes([.font: small, .foregroundColor: Theme.Color.textSecondary], for: .normal)
        filterControl.setTitleTextAttributes([.font: small, .foregroundColor: Theme.Color.textPrimary], for: .selected)
        filterControl.accessibilityLabel = "統計範圍"
        filterControl.addAction(UIAction { [weak self] _ in self?.reload() }, for: .valueChanged)
        stack.addArrangedSubview(filterControl)

        for (index, title) in Self.titles.enumerated() {
            if index > 0 { stack.addArrangedSubview(makeDivider()) }
            stack.addArrangedSubview(makeRow(title: title))
        }
        reload()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func reload() {
        update(provider.summary(for: filter))
    }

    private func update(_ summary: DashboardSummary) {
        let values = [summary.itemCount, summary.expiringSoonCount, summary.expiredCount, summary.reminderCount]
        for (index, (label, value)) in zip(valueLabels, values).enumerated() {
            label.text = value.map(String.init) ?? "—"
            let title = Self.titles[index]
            rows[index].accessibilityLabel = "\(filter.title)\(title) \(value.map { "\($0) 項" } ?? "無資料")"
        }
    }

    private func makeRow(title: String) -> UIView {
        let index = valueLabels.count
        let value = UILabel()
        value.font = Theme.Font.metric
        value.textColor = Theme.Color.textPrimary
        value.adjustsFontForContentSizeCategory = true
        valueLabels.append(value)

        let caption = UILabel()
        caption.text = title
        caption.font = Theme.Font.caption
        caption.textColor = Theme.Color.textSecondary

        let texts = UIStackView(arrangedSubviews: [value, caption])
        texts.axis = .vertical
        texts.spacing = 2
        texts.isUserInteractionEnabled = false

        guard let kind = Self.reminderKinds[index] else {
            texts.isAccessibilityElement = true
            rows.append(texts)
            return texts
        }
        // Reminder rows are buttons (≥ 44pt tall) with a quiet chevron hint.
        let chevron = UIImageView(image: UIImage(systemName: "chevron.right",
                                                 withConfiguration: UIImage.SymbolConfiguration(pointSize: 10, weight: .medium)))
        chevron.tintColor = Theme.Color.divider
        chevron.setContentHuggingPriority(.required, for: .horizontal)
        let content = UIStackView(arrangedSubviews: [texts, chevron])
        content.alignment = .center
        content.isUserInteractionEnabled = false
        content.translatesAutoresizingMaskIntoConstraints = false
        let row = UIControl()
        row.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: row.topAnchor),
            content.bottomAnchor.constraint(equalTo: row.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            row.heightAnchor.constraint(greaterThanOrEqualToConstant: Theme.Metric.minTouchTarget),
        ])
        row.isAccessibilityElement = true
        row.accessibilityTraits = .button
        row.accessibilityHint = "點兩下查看\(title)的食材"
        row.accessibilityIdentifier = "dashboard.\(kind)"
        row.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.onSelectReminder?(kind, self.filter)
        }, for: .touchUpInside)
        rows.append(row)
        return row
    }

    private func makeDivider() -> UIView {
        let line = SketchShapeView()
        line.strokeColor = Theme.Color.divider
        line.seed = UInt64(stack.arrangedSubviews.count)
        line.pathProvider = { rect, seed in
            var rng = SeededRandom(seed: seed)
            let path = UIBezierPath()
            SketchPath.line(from: CGPoint(x: rect.minX, y: rect.midY), to: CGPoint(x: rect.maxX, y: rect.midY),
                            into: path, rng: &rng, wobble: 0.4, overshoot: 0)
            return path
        }
        line.heightAnchor.constraint(equalToConstant: 4).isActive = true
        return line
    }
}
