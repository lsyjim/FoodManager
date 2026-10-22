import UIKit

/// 冰箱管理員完整版: one-time, non-subscription unlock that removes ads. The price shown always comes
/// from StoreKit. Only benefits that exist today are described. No ads on this screen.
final class PremiumPurchaseViewController: UIViewController {
    private let entitlements: EntitlementService
    private let priceLabel = UILabel()
    private let statusLabel = UILabel()
    private lazy var buyButton = UIButton.sketchButton(title: "購買完整版", filled: true)
    private lazy var restoreButton = UIButton.sketchButton(title: "恢復購買")
    private lazy var retryButton = UIButton.sketchButton(title: "重新載入價格", systemImage: "arrow.clockwise")
    private let spinner = UIActivityIndicatorView(style: .medium)

    init(entitlements: EntitlementService) {
        self.entitlements = entitlements
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    static func present(entitlements: EntitlementService, from presenter: UIViewController) {
        let navigation = UINavigationController(rootViewController: PremiumPurchaseViewController(entitlements: entitlements))
        navigation.modalPresentationStyle = .pageSheet
        navigation.sheetPresentationController?.detents = [.large()]
        presenter.present(navigation, animated: true)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.Color.background
        view.accessibilityIdentifier = "purchase"
        let close = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        close.accessibilityLabel = "關閉"
        navigationItem.rightBarButtonItem = close
        buildLayout()
        NotificationCenter.default.addObserver(self, selector: #selector(entitlementsChanged), name: .entitlementsDidChange, object: nil)
        if entitlements.isPremium { showUnlocked() } else { loadPrice() }
    }

    private func buildLayout() {
        let art = UIImageView(image: UIImage(named: "fridge_closed"))
        art.contentMode = .scaleAspectFit
        art.heightAnchor.constraint(equalToConstant: 120).isActive = true
        art.isAccessibilityElement = false

        let title = UILabel()
        title.text = "冰箱管理員完整版"
        title.font = UIFont.preferredFont(forTextStyle: .title1).withWeight(.semibold)
        title.adjustsFontForContentSizeCategory = true
        title.textColor = Theme.Color.textPrimary
        title.textAlignment = .center
        title.numberOfLines = 0

        let benefits = UIStackView(arrangedSubviews: [
            benefitRow("nosign", "永久移除廣告"),
            benefitRow("checkmark.seal", "一次購買，非訂閱"),
            benefitRow("refrigerator", "所有現有功能維持可用，食材數量不限"),
        ])
        benefits.axis = .vertical
        benefits.spacing = 12
        let card = UIView()
        card.backgroundColor = Theme.Color.interior
        card.layer.cornerRadius = 16
        benefits.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(benefits)
        NSLayoutConstraint.activate([
            benefits.topAnchor.constraint(equalTo: card.topAnchor, constant: 18),
            benefits.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -18),
            benefits.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),
            benefits.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -18),
        ])

        priceLabel.font = UIFont.preferredFont(forTextStyle: .title2)
        priceLabel.adjustsFontForContentSizeCategory = true
        priceLabel.textColor = Theme.Color.textPrimary
        priceLabel.textAlignment = .center

        statusLabel.font = UIFont.preferredFont(forTextStyle: .footnote)
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.textColor = Theme.Color.textSecondary
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0

        buyButton.accessibilityIdentifier = "purchase.buy"
        restoreButton.accessibilityIdentifier = "purchase.restore"
        buyButton.addAction(UIAction { [weak self] _ in self?.buy() }, for: .touchUpInside)
        restoreButton.addAction(UIAction { [weak self] _ in self?.restore() }, for: .touchUpInside)
        retryButton.addAction(UIAction { [weak self] _ in self?.loadPrice() }, for: .touchUpInside)
        retryButton.isHidden = true
        for button in [buyButton, restoreButton, retryButton] {
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true
        }

        let stack = UIStackView(arrangedSubviews: [art, title, card, priceLabel, spinner, buyButton, retryButton, restoreButton, statusLabel])
        stack.axis = .vertical
        stack.spacing = 14
        stack.setCustomSpacing(24, after: card)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        view.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -24),
            stack.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -28),
        ])
    }

    private func benefitRow(_ symbol: String, _ text: String) -> UIView {
        let icon = UIImageView(image: UIImage(systemName: symbol))
        icon.tintColor = Theme.Color.stroke
        icon.contentMode = .scaleAspectFit
        icon.widthAnchor.constraint(equalToConstant: 22).isActive = true
        let label = UILabel()
        label.text = text
        label.font = UIFont.preferredFont(forTextStyle: .body)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = Theme.Color.textPrimary
        label.numberOfLines = 0
        let row = UIStackView(arrangedSubviews: [icon, label])
        row.spacing = 12
        row.alignment = .center
        return row
    }

    // MARK: - States

    private func setBusy(_ busy: Bool) {
        busy ? spinner.startAnimating() : spinner.stopAnimating()
        buyButton.isEnabled = !busy && entitlements.product != nil
        restoreButton.isEnabled = !busy
    }

    private func loadPrice() {
        retryButton.isHidden = true
        statusLabel.text = nil
        setBusy(true)
        Task { @MainActor in
            let product = try? await entitlements.loadProduct()
            setBusy(false)
            if let product {
                priceLabel.text = product.displayPrice
                priceLabel.accessibilityLabel = "價格 \(product.displayPrice)"
                buyButton.isEnabled = true
            } else {
                priceLabel.text = nil
                buyButton.isEnabled = false
                retryButton.isHidden = false
                statusLabel.text = "目前無法取得價格，請確認網路連線後再試。"
            }
        }
    }

    private func buy() {
        setBusy(true)
        statusLabel.text = nil
        Task { @MainActor in
            let result = await entitlements.purchase()
            setBusy(false)
            switch result {
            case .purchased: showUnlocked()
            case .cancelled: break
            case .pending: statusLabel.text = "購買正在等待核准（例如家長同意）。核准後會自動解鎖。"
            case let .failed(message): statusLabel.text = message
            }
        }
    }

    private func restore() {
        setBusy(true)
        statusLabel.text = nil
        Task { @MainActor in
            let result = await entitlements.restore()
            setBusy(false)
            switch result {
            case .restored: showUnlocked()
            case .nothingToRestore: statusLabel.text = "這個 Apple ID 沒有可恢復的完整版購買紀錄。"
            case let .failed(message): statusLabel.text = message
            }
        }
    }

    @objc private func entitlementsChanged() {
        if entitlements.isPremium { showUnlocked() }
    }

    private func showUnlocked() {
        priceLabel.text = "已解鎖完整版"
        statusLabel.text = "感謝支持！廣告已移除。"
        buyButton.isHidden = true
        retryButton.isHidden = true
        restoreButton.isHidden = true
        UIAccessibility.post(notification: .announcement, argument: "已解鎖完整版")
    }
}

extension UIFont {
    func withWeight(_ weight: UIFont.Weight) -> UIFont {
        let descriptor = fontDescriptor.addingAttributes([.traits: [UIFontDescriptor.TraitKey.weight: weight]])
        return UIFont(descriptor: descriptor, size: 0)
    }
}
