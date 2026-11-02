import Charts
import SwiftUI
import UIKit

// 食材統計: a UIKit screen; the two charts are small SwiftUI (Swift Charts) views hosted inside it. The app stays
// UIKit. Everything shown is computed by `FoodStatistics` from stored records of the fridges in scope.

/// Soft Morandi tones for categories, assigned by rank so neighbouring slices always differ.
enum StatisticsPalette {
    static let colors: [UIColor] = [0x9DB0A3, 0xC9A99A, 0xA7B5C6, 0xD4C29A, 0xB59FB5, 0x8FA58A, 0xC48E86, 0x9FB8B8,
                                    0xBFAF9F, 0xA3A6C4, 0xC7B07E, 0x94A9A0].map { UIColor(hex: $0) }
    static func color(rank: Int) -> UIColor { colors[rank % colors.count] }
    static let added = UIColor(hex: 0x8FA58A)
    static let consumed = UIColor(hex: 0xC9A99A)
}

// MARK: - Chart models (shared with SwiftUI)

final class ActivityChartModel: ObservableObject {
    @Published var buckets: [ActivityBucket] = []
    @Published var period: StatisticsPeriod = .week
    @Published var selectedStart: Date?

    var isEmpty: Bool { buckets.allSatisfy { $0.added == 0 && $0.consumed == 0 } }
    var selected: ActivityBucket? { buckets.first { $0.start == selectedStart } }

    func select(near date: Date?) {
        guard let date else { selectedStart = nil; return }
        selectedStart = buckets.min { abs($0.start.timeIntervalSince(date)) < abs($1.start.timeIntervalSince(date)) }?.start
    }
}

final class CategoryChartModel: ObservableObject {
    @Published var shares: [CategoryShare] = []
    @Published var selectedID: String?

    var total: Int { shares.reduce(0) { $0 + $1.count } }
    var selected: CategoryShare? { shares.first { $0.category.id == selectedID } }

    /// The slice under a cumulative count value from the angle selection.
    func select(cumulative value: Int?) {
        guard let value else { return }
        var running = 0
        for share in shares {
            running += share.count
            if value < running {
                selectedID = selectedID == share.category.id ? nil : share.category.id
                return
            }
        }
    }

    func toggle(_ id: String) { selectedID = selectedID == id ? nil : id }

    static func percent(_ fraction: Double) -> String { fraction.formatted(.percent.precision(.fractionLength(0...1))) }
}

// MARK: - SwiftUI charts

struct ActivityChartView: View {
    @ObservedObject var model: ActivityChartModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.isEmpty {
                Text("這段期間還沒有放入或食用的紀錄。")
                    .font(.footnote)
                    .foregroundStyle(Color(Theme.Color.textSecondary))
                    .frame(maxWidth: .infinity, minHeight: 160)
            } else {
                Text(selectionText)
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(Color(Theme.Color.textSecondary))
                    .frame(height: 18)
                Chart {
                    ForEach(model.buckets, id: \.start) { bucket in
                        BarMark(x: .value("日期", bucket.start, unit: chartUnit), y: .value("數量", bucket.added))
                            .foregroundStyle(by: .value("類型", "放入"))
                            .position(by: .value("類型", "放入"))
                            .opacity(opacity(for: bucket))
                            .cornerRadius(3)
                            .accessibilityLabel("\(bucket.label) 放入")
                            .accessibilityValue("\(bucket.added) 項")
                        BarMark(x: .value("日期", bucket.start, unit: chartUnit), y: .value("數量", bucket.consumed))
                            .foregroundStyle(by: .value("類型", "食用"))
                            .position(by: .value("類型", "食用"))
                            .opacity(opacity(for: bucket))
                            .cornerRadius(3)
                            .accessibilityLabel("\(bucket.label) 食用")
                            .accessibilityValue("\(bucket.consumed) 項")
                    }
                }
                .chartForegroundStyleScale(["放入": Color(StatisticsPalette.added), "食用": Color(StatisticsPalette.consumed)])
                .chartOverlay { proxy in
                    GeometryReader { geometry in
                        Rectangle().fill(.clear).contentShape(Rectangle())
                            .gesture(SpatialTapGesture().onEnded { tap in
                                guard let plot = proxy.plotFrame else { return }
                                let x = tap.location.x - geometry[plot].origin.x
                                if let date: Date = proxy.value(atX: x) {
                                    let previous = model.selectedStart
                                    model.select(near: date)
                                    if model.selectedStart == previous { model.selectedStart = nil } // tap again to clear
                                }
                            })
                    }
                }
                .chartXAxis {
                    AxisMarks(values: axisDates) { value in
                        AxisValueLabel {
                            if let date = value.as(Date.self) { Text(label(for: date)).font(.caption2) }
                        }
                    }
                }
                .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) }
                .chartLegend(position: .bottom, alignment: .leading)
                .frame(height: 200)
                .animation(.easeOut(duration: 0.25), value: model.buckets)
            }
        }
    }

    private var chartUnit: Calendar.Component { model.period == .halfYear ? .month : .day }

    private func opacity(for bucket: ActivityBucket) -> Double {
        model.selectedStart == nil || model.selectedStart == bucket.start ? 1 : 0.35
    }

    private var selectionText: String {
        guard let bucket = model.selected else { return "點選長條查看數量" }
        return "\(bucket.label)：放入 \(bucket.added) 項 · 食用 \(bucket.consumed) 項"
    }

    /// A readable number of axis labels (every bucket for 7 days / 6 months, every 5th day for 30 days).
    private var axisDates: [Date] {
        let step = model.period == .month ? 5 : 1
        return model.buckets.enumerated().filter { $0.offset % step == 0 }.map(\.element.start)
    }

    private func label(for date: Date) -> String {
        model.buckets.first { $0.start == date }?.label ?? ""
    }
}

struct CategoryDonutView: View {
    @ObservedObject var model: CategoryChartModel

    /// The count position (0..<total, clockwise from 12 o'clock) under a tap on the ring; nil outside the ring.
    static func cumulativeValue(at point: CGPoint, in frame: CGRect, total: Int) -> Int? {
        let dx = point.x - frame.midX, dy = point.y - frame.midY
        let radius = min(frame.width, frame.height) / 2
        let distance = (dx * dx + dy * dy).squareRoot()
        guard total > 0, distance >= radius * 0.55, distance <= radius else { return nil }
        var angle = atan2(dx, -dy)
        if angle < 0 { angle += 2 * .pi }
        return min(Int(angle / (2 * .pi) * Double(total)), total - 1)
    }

    var body: some View {
        if model.shares.isEmpty {
            Text("冰箱裡目前沒有食材。")
                .font(.footnote)
                .foregroundStyle(Color(Theme.Color.textSecondary))
                .frame(maxWidth: .infinity, minHeight: 160)
        } else {
            VStack(spacing: 14) {
                Chart(Array(model.shares.enumerated()), id: \.element.category.id) { rank, share in
                    SectorMark(angle: .value("數量", share.count),
                               innerRadius: .ratio(0.6),
                               outerRadius: .ratio(model.selectedID == share.category.id ? 1 : 0.92),
                               angularInset: 1.5)
                        .cornerRadius(4)
                        .foregroundStyle(Color(StatisticsPalette.color(rank: rank)))
                        .opacity(model.selectedID == nil || model.selectedID == share.category.id ? 1 : 0.4)
                        .accessibilityLabel(share.category.displayName)
                        .accessibilityValue("\(share.count) 項，\(CategoryChartModel.percent(share.fraction))")
                }
                .chartOverlay { proxy in
                    GeometryReader { geometry in
                        Rectangle().fill(.clear).contentShape(Rectangle())
                            .gesture(SpatialTapGesture().onEnded { tap in
                                guard let plot = proxy.plotFrame else { return }
                                model.select(cumulative: Self.cumulativeValue(at: tap.location, in: geometry[plot], total: model.total))
                            })
                    }
                }
                .chartBackground { proxy in
                    GeometryReader { geometry in
                        if let frame = proxy.plotFrame.map({ geometry[$0] }) {
                            centerLabel.position(x: frame.midX, y: frame.midY)
                        }
                    }
                }
                .frame(height: 220)
                .animation(.easeOut(duration: 0.25), value: model.selectedID)

                VStack(spacing: 0) {
                    ForEach(Array(model.shares.enumerated()), id: \.element.category.id) { rank, share in
                        Button { model.toggle(share.category.id) } label: { legendRow(rank: rank, share: share) }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(share.category.displayName)，\(share.count) 項，\(CategoryChartModel.percent(share.fraction))")
                            .accessibilityAddTraits(model.selectedID == share.category.id ? .isSelected : [])
                    }
                }
            }
        }
    }

    private var centerLabel: some View {
        VStack(spacing: 2) {
            if let selected = model.selected {
                Text(selected.category.displayName).font(.subheadline.weight(.medium))
                Text("\(selected.count) 項 · \(CategoryChartModel.percent(selected.fraction))").font(.caption.monospacedDigit())
            } else {
                Text("\(model.total)").font(.title2.weight(.light).monospacedDigit())
                Text("項食材").font(.caption)
            }
        }
        .foregroundStyle(Color(Theme.Color.textPrimary))
        .accessibilityHidden(true)
    }

    private func legendRow(rank: Int, share: CategoryShare) -> some View {
        HStack(spacing: 10) {
            Circle().fill(Color(StatisticsPalette.color(rank: rank))).frame(width: 10, height: 10)
            Image(uiImage: CategoryIconProvider.image(for: share.category.id, size: 24)).resizable().frame(width: 24, height: 24)
            Text(share.category.displayName).font(.subheadline)
            Spacer()
            Text("\(share.count) 項").font(.subheadline.monospacedDigit())
            Text(CategoryChartModel.percent(share.fraction))
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(Color(Theme.Color.textSecondary))
                .frame(minWidth: 52, alignment: .trailing)
        }
        .foregroundStyle(Color(Theme.Color.textPrimary))
        .padding(.vertical, 7)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(model.selectedID == share.category.id ? Color(Theme.Color.fridgeBody) : .clear))
        .contentShape(Rectangle()) // the whole row is tappable, not just its text
    }
}

// MARK: - Screen

final class FoodStatisticsViewController: UIViewController {
    private let loader: FoodAnalyticsLoader
    private let currentFridgeID: UUID
    private let now: () -> Date
    private let statistics = FoodStatistics()

    private var data: FoodAnalyticsData?
    private(set) var loadFailed = false
    private(set) var summary = InventorySummary()
    private(set) var averageDays: Double?
    let activity = ActivityChartModel()
    let categories = CategoryChartModel()

    private lazy var scopeBar = FoodScopeBar(showsFridgeChoice: loader.directory.fridges.count > 1)
    private let periodControl = UISegmentedControl(items: StatisticsPeriod.allCases.map(\.title))
    private let metrics = UIStackView()
    private var metricLabels: [UILabel] = []
    private let averageLabel = UILabel()
    private let errorLabel = UILabel()

    init(loader: FoodAnalyticsLoader, currentFridgeID: UUID, now: @escaping () -> Date = Date.init) {
        self.loader = loader
        self.currentFridgeID = currentFridgeID
        self.now = now
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "食材統計"
        view.backgroundColor = Theme.Color.background
        view.accessibilityIdentifier = "statistics"

        periodControl.selectedSegmentIndex = 0
        periodControl.selectedSegmentTintColor = Theme.Color.interior
        periodControl.accessibilityIdentifier = "statistics.period"
        periodControl.addAction(UIAction { [weak self] _ in self?.recompute() }, for: .valueChanged)
        scopeBar.onChange = { [weak self] in self?.recompute() }

        errorLabel.text = "無法讀取食材資料。下拉或稍後再試。"
        errorLabel.textColor = Theme.Color.destructive
        errorLabel.font = UIFont.preferredFont(forTextStyle: .footnote)
        errorLabel.numberOfLines = 0
        errorLabel.isHidden = true

        let scroll = UIScrollView()
        scroll.alwaysBounceVertical = true
        scroll.refreshControl = UIRefreshControl()
        scroll.refreshControl?.addAction(UIAction { [weak self, weak scroll] _ in
            self?.reload()
            scroll?.refreshControl?.endRefreshing()
        }, for: .valueChanged)
        let stack = UIStackView(arrangedSubviews: [
            scopeBar, periodControl, errorLabel,
            card(title: "概況", content: buildMetrics()),
            card(title: "放入與食用", content: host(ActivityChartView(model: activity))),
            card(title: "目前食材分類", content: host(CategoryDonutView(model: categories)))
        ])
        stack.axis = .vertical
        stack.spacing = 14
        stack.setCustomSpacing(10, after: scopeBar)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 12),
            stack.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: Theme.Metric.gutter),
            stack.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -Theme.Metric.gutter),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -24)
        ])
        for name in [Notification.Name.foodInventoryDidChange, .fridgesDidChange] {
            NotificationCenter.default.addObserver(self, selector: #selector(reload), name: name, object: nil)
        }
        reload()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(false, animated: animated)
    }

    // MARK: Data

    @objc func reload() {
        do {
            data = try loader.load()
            loadFailed = false
        } catch {
            data = nil
            loadFailed = true
        }
        recompute()
    }

    private var period: StatisticsPeriod { StatisticsPeriod.allCases[max(0, periodControl.selectedSegmentIndex)] }

    func recompute() {
        errorLabel.isHidden = !loadFailed
        let scope = FoodAnalyticsScope(fridgeIDs: scopeBar.allFridges ? Set(loader.directory.fridges.map(\.id)) : [currentFridgeID],
                                       storage: scopeBar.storage)
        let items = data?.filtered(scope) ?? []
        let today = now()
        summary = statistics.summary(items: items, period: period, now: today)
        averageDays = statistics.averageStorageDays(items: items, period: period, now: today)
        activity.period = period
        activity.selectedStart = nil
        activity.buckets = statistics.activity(items: items, period: period, now: today)
        let shares = statistics.categoryShares(items: items)
        if !shares.contains(where: { $0.category.id == categories.selectedID }) { categories.selectedID = nil }
        categories.shares = shares
        let values = loadFailed ? ["—", "—", "—", "—"] : [summary.active, summary.expired, summary.expiringSoon, summary.consumedInPeriod].map(String.init)
        for (label, value) in zip(metricLabels, values) { label.text = value }
        averageLabel.text = averageDays.map { "這段期間食用的食材，平均放了 \(String(format: "%.1f", $0)) 天才食用（依放入與食用日期計算，不代表保存期限）。" }
            ?? "這段期間還沒有可計算存放天數的食用紀錄。"
    }

    // MARK: Building

    private func buildMetrics() -> UIView {
        let titles = ["現有食材", "已過期", "即將到期", "期間內食用"]
        let rows = [UIStackView(), UIStackView()]
        for (index, title) in titles.enumerated() {
            let value = UILabel()
            value.font = UIFontMetrics(forTextStyle: .title2).scaledFont(for: Theme.Font.metric)
            value.adjustsFontForContentSizeCategory = true
            value.textColor = Theme.Color.textPrimary
            value.text = "—"
            let caption = UILabel()
            caption.text = title
            caption.font = UIFont.preferredFont(forTextStyle: .caption1)
            caption.adjustsFontForContentSizeCategory = true
            caption.textColor = Theme.Color.textSecondary
            let tile = UIStackView(arrangedSubviews: [value, caption])
            tile.axis = .vertical
            tile.spacing = 2
            tile.isAccessibilityElement = true
            tile.accessibilityIdentifier = "statistics.metric.\(index)"
            metricLabels.append(value)
            rows[index / 2].addArrangedSubview(tile)
        }
        for row in rows { row.distribution = .fillEqually; row.spacing = 12 }
        averageLabel.font = UIFont.preferredFont(forTextStyle: .footnote)
        averageLabel.adjustsFontForContentSizeCategory = true
        averageLabel.textColor = Theme.Color.textSecondary
        averageLabel.numberOfLines = 0
        let stack = UIStackView(arrangedSubviews: rows + [averageLabel])
        stack.axis = .vertical
        stack.spacing = 14
        return stack
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Metric tiles read as "現有食材 12".
        for (label, tile) in zip(metricLabels, metricLabels.compactMap(\.superview)) {
            let caption = (tile as? UIStackView)?.arrangedSubviews.last as? UILabel
            tile.accessibilityLabel = "\(caption?.text ?? "") \(label.text ?? "")"
        }
    }

    private func host<Content: View>(_ view: Content) -> UIView {
        let controller = UIHostingController(rootView: view)
        controller.view.backgroundColor = .clear
        if #available(iOS 16.0, *) { controller.sizingOptions = .intrinsicContentSize }
        addChild(controller)
        controller.didMove(toParent: self)
        return controller.view
    }

    private func card(title: String, content: UIView) -> UIView {
        let label = UILabel()
        label.text = title
        label.font = UIFont.preferredFont(forTextStyle: .headline)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = Theme.Color.textPrimary
        label.accessibilityTraits = .header
        let stack = UIStackView(arrangedSubviews: [label, content])
        stack.axis = .vertical
        stack.spacing = 10
        let container = UIView()
        container.backgroundColor = Theme.Color.interior
        container.layer.cornerRadius = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -14)
        ])
        return container
    }
}
