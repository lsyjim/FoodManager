import UIKit

protocol CompartmentEditSheetDelegate: AnyObject {
    /// Each callback applies the change to the working copy; returns an error message to show, or nil on success.
    func sheet(_ sheet: CompartmentEditSheetController, rename id: UUID, to name: String) -> String?
    func sheet(_ sheet: CompartmentEditSheetController, setStorage id: UUID, to storage: StorageType) -> String?
    func sheet(_ sheet: CompartmentEditSheetController, move id: UUID, _ direction: MoveDirection) -> String?
    func sheet(_ sheet: CompartmentEditSheetController, resize id: UUID, by delta: Double) -> String?
    func sheet(_ sheet: CompartmentEditSheetController, delete id: UUID) -> String?
    func sheetDidDismiss(_ sheet: CompartmentEditSheetController)
}

/// Compact bottom sheet for editing one compartment. Undimmed and short (≈200pt) so the fridge,
/// the selected compartment and the header's Save/Cancel stay visible and tappable, even on an iPhone SE.
final class CompartmentEditSheetController: UIViewController, UITextFieldDelegate, UIAdaptivePresentationControllerDelegate {
    weak var delegate: CompartmentEditSheetDelegate?
    private(set) var compartment: Compartment

    /// Storage choices offered for cabinet compartments, in segment order.
    private static let storageChoices: [StorageType] = [.refrigerated, .frozen]
    static let detentIdentifier = UISheetPresentationController.Detent.Identifier("compartmentEdit")
    static let detentHeight: CGFloat = 200

    private let titleLabel = UILabel()
    private let nameField = UITextField()
    private let storageRow = UIStackView()
    private let storageControl = UISegmentedControl(items: storageChoices.map(\.displayName))
    private let heightLabel = UILabel()
    private let errorLabel = UILabel()
    private lazy var shrinkButton = UIButton.sketchButton(title: "", systemImage: "minus")
    private lazy var growButton = UIButton.sketchButton(title: "", systemImage: "plus")
    private lazy var upButton = UIButton.sketchButton(title: "", systemImage: "arrow.up")
    private lazy var downButton = UIButton.sketchButton(title: "", systemImage: "arrow.down")
    private lazy var deleteButton = UIButton.sketchButton(title: "", systemImage: "trash")

    init(compartment: Compartment) {
        self.compartment = compartment
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .pageSheet
        if let sheet = sheetPresentationController {
            sheet.detents = [.custom(identifier: Self.detentIdentifier) { _ in Self.detentHeight }]
            sheet.largestUndimmedDetentIdentifier = Self.detentIdentifier
            sheet.prefersGrabberVisible = true
            sheet.preferredCornerRadius = 20
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.Color.background
        presentationController?.delegate = self
        buildLayout()
        refresh()
    }

    /// Point the sheet at another (or the updated) compartment without re-presenting it.
    func show(_ compartment: Compartment) {
        if compartment.id != self.compartment.id {
            // Finish a pending rename against the previous compartment before switching.
            commitNameIfNeeded()
            nameField.resignFirstResponder()
            errorLabel.text = nil
        }
        self.compartment = compartment
        if isViewLoaded { refresh() }
    }

    // MARK: - Layout

    private func buildLayout() {
        titleLabel.font = Theme.Font.caption
        titleLabel.textColor = Theme.Color.textSecondary

        nameField.font = Theme.Font.body
        nameField.textColor = Theme.Color.textPrimary
        nameField.backgroundColor = Theme.Color.interior
        nameField.layer.cornerRadius = 8
        nameField.layer.borderWidth = Theme.Metric.strokeWidth
        nameField.layer.borderColor = Theme.Color.divider.cgColor
        nameField.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 10, height: 10))
        nameField.leftViewMode = .always
        nameField.clearButtonMode = .whileEditing
        nameField.returnKeyType = .done
        nameField.delegate = self
        nameField.accessibilityLabel = "隔層名稱"
        nameField.heightAnchor.constraint(equalToConstant: 38).isActive = true

        storageControl.selectedSegmentTintColor = Theme.Color.interior
        storageControl.backgroundColor = Theme.Color.fridgeBody
        storageControl.setTitleTextAttributes([.font: Theme.Font.button, .foregroundColor: Theme.Color.textSecondary], for: .normal)
        storageControl.setTitleTextAttributes([.font: Theme.Font.button, .foregroundColor: Theme.Color.textPrimary], for: .selected)
        storageControl.accessibilityLabel = "儲存類型"
        storageControl.addAction(UIAction { [weak self] _ in self?.storageChanged() }, for: .valueChanged)
        storageControl.widthAnchor.constraint(equalToConstant: 140).isActive = true

        storageRow.addArrangedSubview(makeCaption("儲存類型"))
        storageRow.addArrangedSubview(storageControl)
        storageRow.addArrangedSubview(UIView())
        storageRow.spacing = 10
        storageRow.alignment = .center

        heightLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 15, weight: .regular)
        heightLabel.textColor = Theme.Color.textPrimary
        heightLabel.textAlignment = .center
        heightLabel.widthAnchor.constraint(equalToConstant: 46).isActive = true

        var deleteConfig = deleteButton.configuration
        deleteConfig?.baseForegroundColor = Theme.Color.destructive
        deleteButton.configuration = deleteConfig

        shrinkButton.accessibilityLabel = "降低高度"
        growButton.accessibilityLabel = "增加高度"
        upButton.accessibilityLabel = "上移"
        downButton.accessibilityLabel = "下移"
        deleteButton.accessibilityLabel = "刪除"
        shrinkButton.addAction(UIAction { [weak self] _ in self?.resize(by: -FridgeLayoutEditor.heightStep) }, for: .touchUpInside)
        growButton.addAction(UIAction { [weak self] _ in self?.resize(by: FridgeLayoutEditor.heightStep) }, for: .touchUpInside)
        upButton.addAction(UIAction { [weak self] _ in self?.move(.up) }, for: .touchUpInside)
        downButton.addAction(UIAction { [weak self] _ in self?.move(.down) }, for: .touchUpInside)
        deleteButton.addAction(UIAction { [weak self] _ in self?.deleteTapped() }, for: .touchUpInside)

        let controlsRow = UIStackView(arrangedSubviews: [makeCaption("高度"), shrinkButton, heightLabel, growButton,
                                                         UIView(), upButton, downButton, deleteButton])
        controlsRow.spacing = 6
        controlsRow.alignment = .center
        controlsRow.setCustomSpacing(10, after: growButton)

        errorLabel.font = Theme.Font.caption
        errorLabel.textColor = Theme.Color.destructive
        errorLabel.numberOfLines = 1
        errorLabel.adjustsFontSizeToFitWidth = true

        let stack = UIStackView(arrangedSubviews: [titleLabel, nameField, storageRow, controlsRow, errorLabel])
        stack.axis = .vertical
        stack.spacing = 8
        stack.setCustomSpacing(4, after: titleLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 18),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Theme.Metric.gutter),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Theme.Metric.gutter),
        ])
    }

    private func makeCaption(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = Theme.Font.caption
        label.textColor = Theme.Color.textSecondary
        label.setContentHuggingPriority(.required, for: .horizontal)
        return label
    }

    private func refresh() {
        titleLabel.text = "\(compartment.parentZoneID.displayName) · \(compartment.type.displayName)"
        if !nameField.isFirstResponder { nameField.text = compartment.name }
        heightLabel.text = "\(Int((compartment.normalizedFrame.height * 100).rounded()))%"
        heightLabel.accessibilityLabel = "高度 \(heightLabel.text ?? "")"
        // Door shelves have no temperature choice in Phase 1.1.
        let choices = compartment.parentZoneID.allowedStorageTypes.filter(Self.storageChoices.contains)
        storageRow.isHidden = choices.count < 2
        storageControl.selectedSegmentIndex = Self.storageChoices.firstIndex(of: compartment.storageType)
            ?? UISegmentedControl.noSegment
    }

    // MARK: - Actions

    private func storageChanged() {
        let index = storageControl.selectedSegmentIndex
        guard Self.storageChoices.indices.contains(index) else { return }
        commitNameIfNeeded()
        report(delegate?.sheet(self, setStorage: compartment.id, to: Self.storageChoices[index]))
        refresh()
    }

    private func resize(by delta: Double) {
        commitNameIfNeeded()
        report(delegate?.sheet(self, resize: compartment.id, by: delta))
    }

    private func move(_ direction: MoveDirection) {
        commitNameIfNeeded()
        report(delegate?.sheet(self, move: compartment.id, direction))
    }

    private func deleteTapped() {
        report(delegate?.sheet(self, delete: compartment.id))
    }

    private func commitNameIfNeeded() {
        guard let text = nameField.text, text != compartment.name else { return }
        if let error = delegate?.sheet(self, rename: compartment.id, to: text) {
            nameField.text = compartment.name
            report(error)
        }
    }

    private func report(_ error: String?) {
        errorLabel.text = error
        if error != nil { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
    }

    // MARK: - UITextFieldDelegate / dismissal

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }

    func textFieldDidEndEditing(_ textField: UITextField) {
        commitNameIfNeeded()
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        delegate?.sheetDidDismiss(self)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if nameField.isFirstResponder { nameField.resignFirstResponder() }
    }
}
