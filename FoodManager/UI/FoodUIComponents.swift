import UIKit

/// Display helpers shared by the food list, editor and search.
enum CompartmentNaming {
    /// "櫃內 · 上層"
    static func location(_ compartment: Compartment) -> String {
        "\(compartment.parentZoneID.displayName) · \(compartment.name)"
    }

    /// "櫃內 · 上層（冷藏）", or no suffix for unclassified door shelves.
    static func locationWithStorage(_ compartment: Compartment) -> String {
        compartment.storageType == .unspecified
            ? location(compartment) : "\(location(compartment))（\(compartment.storageType.displayName)）"
    }
}

/// One food row: category icon, name, quantity, storage duration and expiry, optional quick −/+ buttons.
final class FoodItemCell: UITableViewCell {
    static let reuseID = "FoodItemCell"

    var onIncrement: (() -> Void)?
    var onDecrement: (() -> Void)?

    private let iconView = UIImageView()
    private let nameLabel = UILabel()
    private let quantityLabel = UILabel()
    private let detailLabel = UILabel()
    private lazy var minusButton = UIButton.sketchButton(title: "", systemImage: "minus")
    private lazy var plusButton = UIButton.sketchButton(title: "", systemImage: "plus")
    private let controls = UIStackView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = Theme.Color.interior
        iconView.contentMode = .scaleAspectFit
        nameLabel.font = Theme.Font.body
        nameLabel.textColor = Theme.Color.textPrimary
        quantityLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 15, weight: .regular)
        quantityLabel.textColor = Theme.Color.textPrimary
        quantityLabel.setContentHuggingPriority(.required, for: .horizontal)
        quantityLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        detailLabel.font = Theme.Font.caption
        detailLabel.textColor = Theme.Color.textSecondary
        detailLabel.numberOfLines = 2

        minusButton.accessibilityLabel = "減少數量"
        plusButton.accessibilityLabel = "增加數量"
        minusButton.addAction(UIAction { [weak self] _ in self?.onDecrement?() }, for: .touchUpInside)
        plusButton.addAction(UIAction { [weak self] _ in self?.onIncrement?() }, for: .touchUpInside)
        for button in [minusButton, plusButton] {
            button.widthAnchor.constraint(equalToConstant: 36).isActive = true
        }
        controls.addArrangedSubview(minusButton)
        controls.addArrangedSubview(plusButton)
        controls.spacing = 6

        let titleRow = UIStackView(arrangedSubviews: [nameLabel, quantityLabel])
        titleRow.spacing = 8
        let texts = UIStackView(arrangedSubviews: [titleRow, detailLabel])
        texts.axis = .vertical
        texts.spacing = 3
        let row = UIStackView(arrangedSubviews: [iconView, texts, controls])
        row.spacing = 12
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(row)
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 32),
            iconView.heightAnchor.constraint(equalToConstant: 32),
            row.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            row.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10),
            row.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// `location` is shown in search results; nil in a compartment's own list.
    func configure(_ item: FoodItem, location: String?, showsQuantityControls: Bool,
                   evaluator: FoodReminderEvaluator, now: Date) {
        iconView.image = CategoryIconProvider.image(for: item.categoryID, size: 32)
        nameLabel.text = item.name
        quantityLabel.text = FoodFormatting.quantityText(item.quantity, unit: item.unit)
        controls.isHidden = !showsQuantityControls

        let days = FoodDateCalculator(calendar: evaluator.calendar).daysStored(since: item.storedAt, now: now)
        var parts = [FoodFormatting.storageText(daysStored: days)]
        if let location { parts.insert(location, at: 0) }
        let status = evaluator.expirationStatus(of: item, now: now)
        let detail = NSMutableAttributedString(string: parts.joined(separator: " · "))
        if let expiry = FoodFormatting.expirationText(status) {
            let color: UIColor
            switch status {
            case .expired: color = Theme.Color.destructive
            case .expiringSoon: color = Theme.Color.textPrimary
            default: color = Theme.Color.textSecondary
            }
            detail.append(NSAttributedString(string: " · "))
            detail.append(NSAttributedString(string: expiry, attributes: [.foregroundColor: color]))
        }
        if evaluator.isStorageReminderDue(item, now: now) {
            detail.append(NSAttributedString(string: " · 保存提醒", attributes: [.foregroundColor: Theme.Color.textPrimary]))
        }
        detailLabel.attributedText = detail
        accessibilityLabel = "\(item.name)，\(quantityLabel.text ?? "")，\(detail.string)"
    }
}

/// Food actions that need confirmation or a choice, shared by every screen that shows food.
enum FoodActions {
    /// Asks to mark an item consumed when its quantity would reach zero. Nothing changes on Cancel.
    static func confirmConsumed(_ item: FoodItem, inventory: FoodInventoryService, from presenter: UIViewController,
                                completion: (() -> Void)? = nil) {
        let alert = UIAlertController(title: "「\(item.name)」數量將變為 0", message: "要標記為已食用嗎？已食用的食材會從冰箱中移除。",
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "標記為已食用", style: .default) { _ in
            perform(on: presenter) { try inventory.markConsumed(item.id) }
            completion?()
        })
        presenter.present(alert, animated: true)
    }

    /// Lets the user pick another compartment. Moving keeps the same record, ID and dates.
    static func presentMove(_ item: FoodItem, inventory: FoodInventoryService, compartments: [Compartment],
                            from presenter: UIViewController, sourceView: UIView?) {
        let sheet = UIAlertController(title: "移動「\(item.name)」", message: "放入日期會保留", preferredStyle: .actionSheet)
        for compartment in compartments where compartment.id != item.compartmentID {
            sheet.addAction(UIAlertAction(title: CompartmentNaming.locationWithStorage(compartment), style: .default) { _ in
                perform(on: presenter) { try inventory.move(item.id, to: compartment.id) }
            })
        }
        sheet.addAction(UIAlertAction(title: "取消", style: .cancel))
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = sourceView ?? presenter.view
            popover.sourceRect = sourceView?.bounds ?? presenter.view.bounds
        }
        presenter.present(sheet, animated: true)
    }

    /// Runs a mutation and shows a readable error if it fails.
    static func perform(on presenter: UIViewController, _ action: () throws -> Void) {
        do {
            try action()
        } catch let error as FoodValidationError {
            showError(error.message, on: presenter)
        } catch {
            showError("操作失敗，請再試一次。", on: presenter)
        }
    }

    static func showError(_ message: String, on presenter: UIViewController) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default))
        presenter.present(alert, animated: true)
    }
}
