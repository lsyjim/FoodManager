import UIKit

/// Holds the closed-home banner. Takes no space (height 0, hidden) until an ad has actually loaded,
/// collapses on failure, retries with exponential back-off (never in a tight loop) and releases the
/// ad view entirely when ads are no longer allowed (e.g. right after a Premium purchase).
@MainActor
final class BannerAdContainerView: UIView {
    static let retryDelays: [TimeInterval] = [30, 60, 120, 300, 600]

    private let makeLoader: () -> BannerAdLoading
    /// Schedules retries; injectable so tests don't wait.
    var scheduleRetry: (TimeInterval, @escaping @MainActor () -> Void) -> Void = { delay, work in
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            work()
        }
    }
    private(set) var loader: BannerAdLoading?
    private(set) var isLoaded = false
    private(set) var failureCount = 0
    private var requestedWidth: CGFloat = 0
    private var retryGeneration = 0
    private weak var rootViewController: UIViewController?
    private lazy var heightConstraint = heightAnchor.constraint(equalToConstant: 0)

    init(makeLoader: @escaping () -> BannerAdLoading) {
        self.makeLoader = makeLoader
        super.init(frame: .zero)
        heightConstraint.isActive = true
        clipsToBounds = true
        isHidden = true
        accessibilityIdentifier = "home.adBanner"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Height the banner will take once loaded for a given width (adaptive banners ≈ 50–90pt).
    var loadedHeight: CGFloat { isLoaded ? heightConstraint.constant : 0 }

    /// Starts (or keeps) a banner of `width`. No-op while a request for the same width is in flight or loaded.
    func activate(width: CGFloat, rootViewController: UIViewController) {
        guard width > 0 else { return }
        self.rootViewController = rootViewController
        if loader != nil && abs(width - requestedWidth) < 1 { return }
        requestedWidth = width
        load()
    }

    /// Stops requesting, removes the ad view and frees it.
    func deactivate() {
        guard loader != nil || isLoaded || !isHidden else { return } // already inactive (called on every layout)
        retryGeneration += 1
        loader?.destroy()
        loader = nil
        isLoaded = false
        failureCount = 0
        requestedWidth = 0
        collapse()
    }

    private func load() {
        guard let rootViewController else { return }
        let loader = self.loader ?? makeLoader()
        self.loader = loader
        loader.onLoaded = { [weak self] in self?.didLoad() }
        loader.onFailed = { [weak self] _ in self?.didFail() }
        let size = loader.load(width: requestedWidth, rootViewController: rootViewController)
        if let view = loader.view, view.superview !== self {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
            NSLayoutConstraint.activate([
                view.centerXAnchor.constraint(equalTo: centerXAnchor),
                view.topAnchor.constraint(equalTo: topAnchor),
                view.widthAnchor.constraint(equalToConstant: size.width),
                view.heightAnchor.constraint(equalToConstant: size.height),
            ])
        }
        pendingHeight = size.height
    }

    private var pendingHeight: CGFloat = 0

    private func didLoad() {
        isLoaded = true
        failureCount = 0
        heightConstraint.constant = pendingHeight
        isHidden = false
        superview?.layoutIfNeeded()
    }

    private func didFail() {
        isLoaded = false
        collapse()
        let delay = Self.retryDelays[min(failureCount, Self.retryDelays.count - 1)]
        failureCount += 1
        let generation = retryGeneration
        scheduleRetry(delay) { [weak self] in
            guard let self, self.retryGeneration == generation, self.loader != nil else { return }
            self.load()
        }
    }

    private func collapse() {
        heightConstraint.constant = 0
        isHidden = true
        superview?.layoutIfNeeded()
    }
}
