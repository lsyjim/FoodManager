import UIKit

/// Shown instead of the fridge when persistent storage can't be opened. No data-changing screen is
/// reachable from here, so nothing can be "saved" into temporary storage. The existing database is untouched.
final class StorageUnavailableViewController: UIViewController {
    var onRetry: (() -> Void)?

    private let messageLabel = UILabel()
    private lazy var retryButton = UIButton.sketchButton(title: "重試", systemImage: "arrow.clockwise", filled: true)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.Color.background

        let icon = UIImageView(image: UIImage(systemName: "externaldrive.badge.exclamationmark"))
        icon.tintColor = Theme.Color.stroke
        icon.contentMode = .scaleAspectFit
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 40, weight: .light)

        let title = UILabel()
        title.text = "暫時無法存取冰箱資料"
        title.font = UIFont.preferredFont(forTextStyle: .title2)
        title.adjustsFontForContentSizeCategory = true
        title.textColor = Theme.Color.textPrimary
        title.textAlignment = .center
        title.numberOfLines = 0

        messageLabel.text = """
        資料儲存空間目前無法開啟，為避免變更沒有真正儲存，暫時不能新增或修改食材。
        你原本的資料沒有被刪除。請稍後再試，或確認裝置仍有足夠的儲存空間。
        """
        messageLabel.font = UIFont.preferredFont(forTextStyle: .body)
        messageLabel.adjustsFontForContentSizeCategory = true
        messageLabel.textColor = Theme.Color.textSecondary
        messageLabel.textAlignment = .center
        messageLabel.numberOfLines = 0

        retryButton.accessibilityIdentifier = "storage.retry"
        retryButton.addAction(UIAction { [weak self] _ in self?.onRetry?() }, for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [icon, title, messageLabel, retryButton])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -32),
            retryButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 140),
        ])
    }

    /// Feedback after a retry that still failed.
    func showRetryFailed() {
        UINotificationFeedbackGenerator().notificationOccurred(.error)
        UIAccessibility.post(notification: .announcement, argument: "仍無法存取資料，請稍後再試")
    }
}
