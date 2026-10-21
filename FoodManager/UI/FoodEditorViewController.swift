import UIKit

/// Add / edit food form. Works on a `FoodDraft`; nothing is persisted until 儲存, and 取消 discards everything.
final class FoodEditorViewController: UIViewController {
    enum Mode: Equatable {
        /// `compartmentID` is pre-selected when opened from a compartment; nil for the global entry point.
        case add(compartmentID: UUID?)
        case edit(foodID: UUID)
    }

    private let mode: Mode
    private let inventory: FoodInventoryService
    private let compartments: [Compartment]
    private let favoriteStore: FavoriteCategoryStore
    private let favoriteFoodStore: FavoriteFoodStore
    private var favoriteFoods = FavoriteFoods()
    private var recentSuggestions: [FoodTemplate] = []
    private let favoritesRow = UIStackView()
    private let favoritesHint = UILabel()
    private let recentRow = UIStackView()
    private lazy var recentSection = UIView()
    /// Internal (not private) so tests can drive submissions without the form.
    var draft: FoodDraft

    private let scrollView = UIScrollView()
    private let stack = UIStackView()
    private let errorLabel = UILabel()
    private let nameField = UITextField()
    private let categoryButton = UIButton(type: .system)
    private let quantityField = UITextField()
    private let unitField = UITextField()
    private let unitMenuButton = UIButton(type: .system)
    private let locationButton = UIButton(type: .system)
    private let storedPicker = UIDatePicker()
    private let expirySwitch = UISwitch()
    private let expiryPicker = UIDatePicker()
    private let reminderSwitch = UISwitch()
    private let reminderStepper = UIStepper()
    private let reminderLabel = UILabel()

    init(mode: Mode, inventory: FoodInventoryService, compartments: [Compartment],
         favoriteStore: FavoriteCategoryStore = UserDefaultsFavoriteCategoryStore(),
         favoriteFoodStore: FavoriteFoodStore = UserDefaultsFavoriteFoodStore()) {
        self.favoriteStore = favoriteStore
        self.favoriteFoodStore = favoriteFoodStore
        self.mode = mode
        self.inventory = inventory
        self.compartments = compartments
        switch mode {
        case let .add(compartmentID):
            draft = FoodDraft(compartmentID: compartmentID, now: inventory.now())
        case let .edit(foodID):
            draft = inventory.item(id: foodID).map(FoodDraft.init(item:)) ?? FoodDraft(now: inventory.now())
        }
        // A record whose compartment vanished must be re-assigned before it can be saved.
        if let id = draft.compartmentID, !compartments.contains(where: { $0.id == id }) {
            draft.compartmentID = nil
        }
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Wraps the editor in a navigation controller presented as a large sheet.
    static func present(_ mode: Mode, inventory: FoodInventoryService, compartments: [Compartment],
                        from presenter: UIViewController) {
        let editor = FoodEditorViewController(mode: mode, inventory: inventory, compartments: compartments)
        let navigation = UINavigationController(rootViewController: editor)
        navigation.modalPresentationStyle = .pageSheet
        navigation.isModalInPresentation = true // only 取消 / 儲存 close it, so edits are never lost by accident
        navigation.sheetPresentationController?.detents = [.large()]
        presenter.present(navigation, animated: true)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.Color.background
        title = isEditMode ? "編輯食材" : "新增食材"
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "取消", primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        })
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "儲存", primaryAction: UIAction { [weak self] _ in
            self?.save()
        })
        navigationItem.rightBarButtonItem?.style = .done
        navigationItem.rightBarButtonItem?.accessibilityIdentifier = "food.save"
        buildForm()
        populate()
    }

    private var isEditMode: Bool {
        if case .edit = mode { return true } else { return false }
    }

    // MARK: - Form

    private func buildForm() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.keyboardDismissMode = .interactive
        view.addSubview(scrollView)
        stack.axis = .vertical
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stack)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -24),
            stack.leadingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.leadingAnchor, constant: Theme.Metric.gutter),
            stack.trailingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.trailingAnchor, constant: -Theme.Metric.gutter),
        ])

        errorLabel.font = Theme.Font.caption
        errorLabel.textColor = Theme.Color.destructive
        errorLabel.numberOfLines = 0
        errorLabel.isHidden = true
        stack.addArrangedSubview(errorLabel)
        if !isEditMode { buildQuickEntry() }

        styleField(nameField, placeholder: "例如：牛奶")
        nameField.returnKeyType = .done
        nameField.addAction(UIAction { [weak self] _ in self?.nameField.resignFirstResponder() }, for: .editingDidEndOnExit)
        nameField.addAction(UIAction { [weak self] _ in self?.reloadRecentRow() }, for: .editingChanged)
        nameField.accessibilityIdentifier = "food.name"
        locationButton.accessibilityIdentifier = "food.location"
        expirySwitch.accessibilityIdentifier = "food.expirySwitch"
        stack.addArrangedSubview(section("食材名稱", nameField))

        styleMenuButton(categoryButton)
        categoryButton.showsMenuAsPrimaryAction = false
        var categoryConfig = categoryButton.configuration
        categoryConfig?.indicator = .none
        categoryButton.configuration = categoryConfig
        categoryButton.addAction(UIAction { [weak self] _ in self?.openCategoryPicker() }, for: .touchUpInside)
        stack.addArrangedSubview(section("分類", categoryButton))

        styleField(quantityField, placeholder: "1")
        quantityField.keyboardType = .decimalPad
        quantityField.textAlignment = .center
        quantityField.widthAnchor.constraint(equalToConstant: 76).isActive = true
        quantityField.accessibilityLabel = "數量"
        let minus = UIButton.sketchButton(title: "", systemImage: "minus")
        let plus = UIButton.sketchButton(title: "", systemImage: "plus")
        minus.accessibilityLabel = "減少數量"
        plus.accessibilityLabel = "增加數量"
        minus.addAction(UIAction { [weak self] _ in self?.stepQuantity(by: -1) }, for: .touchUpInside)
        plus.addAction(UIAction { [weak self] _ in self?.stepQuantity(by: 1) }, for: .touchUpInside)
        styleField(unitField, placeholder: "單位")
        unitField.widthAnchor.constraint(equalToConstant: 64).isActive = true
        unitField.textAlignment = .center
        unitField.accessibilityLabel = "單位"
        unitMenuButton.setImage(UIImage(systemName: "chevron.down"), for: .normal)
        unitMenuButton.tintColor = Theme.Color.textSecondary
        unitMenuButton.accessibilityLabel = "選擇單位"
        unitMenuButton.showsMenuAsPrimaryAction = true
        unitMenuButton.menu = UIMenu(children: FoodFormatting.presetUnits.map { unit in
            UIAction(title: unit) { [weak self] _ in self?.unitField.text = unit }
        })
        let quantityRow = UIStackView(arrangedSubviews: [minus, quantityField, plus, UIView(), unitField, unitMenuButton])
        quantityRow.spacing = 8
        quantityRow.alignment = .center
        stack.addArrangedSubview(section("數量與單位", quantityRow))

        styleMenuButton(locationButton)
        locationButton.menu = UIMenu(children: compartments.map { compartment in
            UIAction(title: CompartmentNaming.locationWithStorage(compartment)) { [weak self] _ in
                self?.draft.compartmentID = compartment.id
                self?.populateLocation()
            }
        })
        stack.addArrangedSubview(section("存放位置", locationButton))

        for picker in [storedPicker, expiryPicker] {
            picker.datePickerMode = .date
            picker.preferredDatePickerStyle = .compact
            picker.tintColor = Theme.Color.stroke
        }
        storedPicker.accessibilityLabel = "放入日期"
        stack.addArrangedSubview(section("放入日期", leadingRow([storedPicker])))

        expiryPicker.accessibilityLabel = "到期日"
        expirySwitch.onTintColor = Theme.Color.stroke
        expirySwitch.accessibilityLabel = "設定到期日"
        expirySwitch.addAction(UIAction { [weak self] _ in self?.updateOptionalRows() }, for: .valueChanged)
        stack.addArrangedSubview(section("到期日（選填）", leadingRow([expirySwitch, expiryPicker])))

        reminderSwitch.onTintColor = Theme.Color.stroke
        reminderSwitch.accessibilityLabel = "設定保存提醒"
        reminderSwitch.addAction(UIAction { [weak self] _ in self?.updateOptionalRows() }, for: .valueChanged)
        reminderStepper.minimumValue = Double(FoodValidationError.reminderDayRange.lowerBound)
        reminderStepper.maximumValue = 365
        reminderStepper.addAction(UIAction { [weak self] _ in self?.updateReminderLabel() }, for: .valueChanged)
        reminderLabel.font = Theme.Font.body
        reminderLabel.textColor = Theme.Color.textPrimary
        stack.addArrangedSubview(section("保存提醒（選填）", leadingRow([reminderSwitch, reminderLabel, UIView(), reminderStepper])))

        if !isEditMode {
            let saveAndContinue = UIButton.sketchButton(title: "儲存並繼續新增", systemImage: "plus")
            saveAndContinue.accessibilityIdentifier = "food.saveAndContinue"
            saveAndContinue.addAction(UIAction { [weak self] _ in self?.saveAndContinue() }, for: .touchUpInside)
            stack.setCustomSpacing(24, after: stack.arrangedSubviews.last!)
            stack.addArrangedSubview(saveAndContinue)
        }

        if isEditMode {
            let consumed = UIButton.sketchButton(title: "標記為已食用", systemImage: "checkmark")
            consumed.addAction(UIAction { [weak self] _ in self?.markConsumed() }, for: .touchUpInside)
            let delete = UIButton.sketchButton(title: "刪除", systemImage: "trash")
            var config = delete.configuration
            config?.baseForegroundColor = Theme.Color.destructive
            delete.configuration = config
            delete.addAction(UIAction { [weak self] _ in self?.confirmDelete() }, for: .touchUpInside)
            let actions = UIStackView(arrangedSubviews: [consumed, UIView(), delete])
            actions.alignment = .center
            stack.setCustomSpacing(28, after: stack.arrangedSubviews.last!)
            stack.addArrangedSubview(actions)
        }
    }

    // MARK: - Fast entry (favorites + recent)

    private func buildQuickEntry() {
        favoriteFoods = favoriteFoodStore.load()
        recentSuggestions = inventory.recentFoodSuggestions()

        let pinCurrent = UIButton(type: .system)
        pinCurrent.setTitle("加入常用", for: .normal)
        pinCurrent.setImage(UIImage(systemName: "pin"), for: .normal)
        pinCurrent.titleLabel?.font = UIFont.preferredFont(forTextStyle: .footnote)
        pinCurrent.tintColor = Theme.Color.stroke
        pinCurrent.accessibilityLabel = "把目前的名稱、分類與單位加入常用食材"
        pinCurrent.addAction(UIAction { [weak self] _ in self?.pinCurrentAsFavorite() }, for: .touchUpInside)

        favoritesHint.text = "填好名稱後按「加入常用」，下次一鍵帶入"
        favoritesHint.font = UIFont.preferredFont(forTextStyle: .footnote)
        favoritesHint.textColor = Theme.Color.textSecondary
        favoritesHint.numberOfLines = 0

        let favoritesHeader = UIStackView(arrangedSubviews: [caption("常用食材"), UIView(), pinCurrent])
        favoritesHeader.alignment = .center
        let favorites = UIStackView(arrangedSubviews: [favoritesHeader, chipScroller(favoritesRow), favoritesHint])
        favorites.axis = .vertical
        favorites.spacing = 6
        stack.addArrangedSubview(favorites)

        let recent = UIStackView(arrangedSubviews: [caption("最近使用"), chipScroller(recentRow)])
        recent.axis = .vertical
        recent.spacing = 6
        recentSection = recent
        stack.addArrangedSubview(recent)
        stack.setCustomSpacing(20, after: recent)

        reloadFavoritesRow()
        reloadRecentRow()
    }

    private func caption(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = Theme.Font.caption
        label.textColor = Theme.Color.textSecondary
        return label
    }

    private func chipScroller(_ row: UIStackView) -> UIScrollView {
        let scroller = UIScrollView()
        scroller.showsHorizontalScrollIndicator = false
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        scroller.addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: scroller.contentLayoutGuide.topAnchor),
            row.bottomAnchor.constraint(equalTo: scroller.contentLayoutGuide.bottomAnchor),
            row.leadingAnchor.constraint(equalTo: scroller.contentLayoutGuide.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: scroller.contentLayoutGuide.trailingAnchor),
            row.heightAnchor.constraint(equalTo: scroller.frameLayoutGuide.heightAnchor),
            scroller.heightAnchor.constraint(equalToConstant: 40),
        ])
        return scroller
    }

    private func chip(_ template: FoodTemplate, identifier: String) -> UIButton {
        var config = UIButton.Configuration.plain()
        config.title = template.name
        config.image = CategoryIconProvider.image(for: template.categoryID, size: 20).withRenderingMode(.alwaysOriginal)
        config.imagePadding = 6
        config.baseForegroundColor = Theme.Color.textPrimary
        config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 12)
        let button = UIButton(configuration: config)
        button.backgroundColor = Theme.Color.interior
        button.layer.cornerRadius = 18
        button.layer.borderWidth = Theme.Metric.strokeWidth
        button.layer.borderColor = Theme.Color.divider.cgColor
        button.accessibilityIdentifier = identifier
        button.accessibilityHint = "點兩下帶入名稱、分類與單位"
        button.addAction(UIAction { [weak self] _ in self?.applyTemplate(template) }, for: .touchUpInside)
        return button
    }

    private func reloadFavoritesRow() {
        favoritesRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, favorite) in favoriteFoods.templates.enumerated() {
            let button = chip(favorite.template, identifier: "food.favorite.\(favorite.name)")
            // Long-press: unpin or reorder manually (order never changes automatically).
            var actions: [UIMenuElement] = [UIAction(title: "取消釘選", image: UIImage(systemName: "pin.slash")) { [weak self] _ in
                self?.updateFavorites { $0.unpin(favorite.id) }
            }]
            if index > 0 {
                actions.append(UIAction(title: "往前移", image: UIImage(systemName: "arrow.left")) { [weak self] _ in
                    self?.updateFavorites { $0.move(from: index, to: index - 1) }
                })
            }
            if index < favoriteFoods.templates.count - 1 {
                actions.append(UIAction(title: "往後移", image: UIImage(systemName: "arrow.right")) { [weak self] _ in
                    self?.updateFavorites { $0.move(from: index, to: index + 1) }
                })
            }
            button.menu = UIMenu(children: actions)
            favoritesRow.addArrangedSubview(button)
        }
        favoritesHint.isHidden = !favoriteFoods.templates.isEmpty
        favoritesRow.superview?.isHidden = favoriteFoods.templates.isEmpty // no empty gap
    }

    private func reloadRecentRow() {
        guard !isEditMode else { return }
        recentRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let matches = RecentFoodSuggestions.filter(recentSuggestions, query: nameField.text ?? "")
            .filter { FoodNameKey.normalize($0.name) != FoodNameKey.normalize(nameField.text ?? "") }
        for template in matches { recentRow.addArrangedSubview(chip(template, identifier: "food.recent.\(template.name)")) }
        recentSection.isHidden = matches.isEmpty
    }

    private func updateFavorites(_ change: (inout FavoriteFoods) -> Void) {
        change(&favoriteFoods)
        favoriteFoodStore.save(favoriteFoods)
        reloadFavoritesRow()
    }

    /// Fills name, category, unit (and a still-valid preferred compartment) and leaves every other field
    /// untouched; the user can still edit everything afterwards.
    func applyTemplate(_ template: FoodTemplate) {
        draft.apply(template, validCompartmentIDs: Set(compartments.map(\.id)))
        nameField.text = draft.name
        unitField.text = draft.unit
        populateCategory()
        populateLocation()
        errorLabel.isHidden = true
        reloadRecentRow()
        UISelectionFeedbackGenerator().selectionChanged()
    }

    private func pinCurrentAsFavorite() {
        let name = nameField.text ?? ""
        let template = FoodTemplate(name: name, categoryID: draft.categoryID,
                                    unit: (unitField.text ?? "").trimmingCharacters(in: .whitespaces).isEmpty ? "個" : unitField.text!,
                                    preferredCompartmentID: draft.compartmentID)
        do {
            try favoriteFoods.pin(template)
            favoriteFoodStore.save(favoriteFoods)
            reloadFavoritesRow()
            ToastView.show("已加入常用食材", in: view)
        } catch let error as FavoriteFoodError {
            showError(error.message)
        } catch {}
    }

    // MARK: - Continuous entry

    private func saveAndContinue() {
        view.endEditing(true)
        if let message = readForm() { return showError(message) }
        let savedName = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        switch submitSave() {
        case .success:
            prepareNextEntry()
            ToastView.show("已新增「\(savedName)」", in: view)
            nameField.becomeFirstResponder()
        case let .failure(message):
            showError(message) // the form keeps everything the user typed
        case .needsConsumeConfirmation:
            break
        }
    }

    /// Resets the form for the next item: keeps the compartment (if still valid) and storedAt date;
    /// clears name, quantity (→ 1), category (→ 其他), unit, expiration and storage reminder.
    func prepareNextEntry() {
        draft = draft.nextEntry(validCompartmentIDs: Set(compartments.map(\.id)))
        recentSuggestions = inventory.recentFoodSuggestions()
        errorLabel.isHidden = true
        populate()
        reloadRecentRow()
    }

    private func populate() {
        nameField.text = draft.name
        populateCategory()
        quantityField.text = FoodFormatting.number(draft.quantity)
        unitField.text = draft.unit
        populateLocation()
        storedPicker.date = draft.storedAt
        expirySwitch.isOn = draft.expirationDate != nil
        // Turning expiry on starts at today for the user to change; no expiry date is ever guessed.
        expiryPicker.date = draft.expirationDate ?? inventory.now()
        reminderSwitch.isOn = draft.storageReminderDays != nil
        reminderStepper.value = Double(draft.storageReminderDays ?? 7)
        updateOptionalRows()
    }

    private func populateCategory() {
        let category = FoodCategoryCatalog.category(id: draft.categoryID)
        setMenuButton(categoryButton, title: category.displayName, color: Theme.Color.textPrimary,
                      image: CategoryIconProvider.image(for: category.id, size: 22).withRenderingMode(.alwaysOriginal))
    }

    private func populateLocation() {
        if let id = draft.compartmentID, let compartment = compartments.first(where: { $0.id == id }) {
            setMenuButton(locationButton, title: CompartmentNaming.locationWithStorage(compartment),
                          color: Theme.Color.textPrimary, image: nil)
        } else {
            setMenuButton(locationButton, title: "請選擇存放位置", color: Theme.Color.textSecondary, image: nil)
        }
    }

    /// Pushes the full picker (search + pinned favorites). Picking a category returns to the form.
    private func openCategoryPicker() {
        view.endEditing(true)
        let picker = CategoryPickerViewController(selectedID: draft.categoryID, store: favoriteStore)
        picker.onSelect = { [weak self] id in
            self?.draft.categoryID = id
            self?.populateCategory()
            self?.navigationController?.popViewController(animated: true)
        }
        navigationController?.pushViewController(picker, animated: true)
    }

    private func updateOptionalRows() {
        expiryPicker.isHidden = !expirySwitch.isOn
        reminderStepper.isHidden = !reminderSwitch.isOn
        updateReminderLabel()
    }

    private func updateReminderLabel() {
        reminderLabel.text = reminderSwitch.isOn ? "存放 \(Int(reminderStepper.value)) 天後提醒" : "不提醒"
    }

    private func stepQuantity(by delta: Decimal) {
        let current = FoodFormatting.parseQuantity(quantityField.text ?? "") ?? draft.quantity
        quantityField.text = FoodFormatting.number(max(0, current + delta))
    }

    // MARK: - Actions

    /// Copies the form into the draft; returns an error message if a field can't be read.
    private func readForm() -> String? {
        draft.name = nameField.text ?? ""
        draft.unit = unitField.text ?? ""
        guard let quantity = FoodFormatting.parseQuantity(quantityField.text ?? "") else { return "請輸入有效的數量" }
        draft.quantity = quantity
        draft.storedAt = storedPicker.date
        draft.expirationDate = expirySwitch.isOn ? expiryPicker.date : nil
        draft.storageReminderDays = reminderSwitch.isOn ? Int(reminderStepper.value) : nil
        return nil
    }

    // MARK: - Submitting
    //
    // Every action closes the editor only after the write succeeded. On failure the editor stays open with
    // the user's input intact and an inline error. `isSubmitting` blocks repeated taps while a write runs.

    /// Called instead of `dismiss` when set (tests); production dismisses the sheet.
    var onFinished: (() -> Void)?
    private(set) var isSubmitting = false

    private func save() {
        view.endEditing(true)
        if let message = readForm() { return showError(message) }
        switch submitSave() {
        case .success: finish()
        case .needsConsumeConfirmation:
            guard case let .edit(foodID) = mode, let item = inventory.item(id: foodID) else { return }
            FoodActions.confirmConsumed(item, inventory: inventory, from: self) { [weak self] in self?.finish() }
        case let .failure(message):
            showError(message)
        }
    }

    enum SubmitResult: Equatable {
        case success
        case needsConsumeConfirmation
        case failure(String)
    }

    /// Persists the current draft. Internal so tests can drive it without UI.
    func submitSave() -> SubmitResult {
        guard begin() else { return .failure("正在儲存，請稍候") }
        defer { isSubmitting = false; setControlsEnabled(true) }
        do {
            switch mode {
            case .add: try inventory.add(draft)
            case let .edit(foodID): try inventory.update(foodID, with: draft)
            }
            if draft.expirationDate != nil || draft.storageReminderDays != nil {
                NotificationCenter.default.post(name: .foodReminderConfigured, object: nil)
            }
            return .success
        } catch FoodValidationError.zeroQuantity {
            return isEditMode ? .needsConsumeConfirmation : .failure("數量需大於 0")
        } catch let error as FoodValidationError {
            return .failure(error.message)
        } catch {
            return .failure("儲存失敗，資料沒有變更。請再試一次。")
        }
    }

    func submitConsumed() -> SubmitResult {
        guard case let .edit(foodID) = mode else { return .failure("找不到這筆食材") }
        guard begin() else { return .failure("正在儲存，請稍候") }
        defer { isSubmitting = false; setControlsEnabled(true) }
        do {
            try inventory.markConsumed(foodID)
            return .success
        } catch {
            return .failure("無法標記為已食用，資料沒有變更。請再試一次。")
        }
    }

    func submitDelete() -> SubmitResult {
        guard case let .edit(foodID) = mode else { return .failure("找不到這筆食材") }
        guard begin() else { return .failure("正在儲存，請稍候") }
        defer { isSubmitting = false; setControlsEnabled(true) }
        do {
            try inventory.delete(foodID)
            return .success
        } catch {
            return .failure("無法刪除，資料沒有變更。請再試一次。")
        }
    }

    private func begin() -> Bool {
        guard !isSubmitting else { return false }
        isSubmitting = true
        setControlsEnabled(false)
        return true
    }

    private func setControlsEnabled(_ enabled: Bool) {
        navigationItem.leftBarButtonItem?.isEnabled = enabled
        navigationItem.rightBarButtonItem?.isEnabled = enabled
    }

    private func finish() {
        if let onFinished { onFinished() } else { dismiss(animated: true) }
    }

    private func markConsumed() {
        switch submitConsumed() {
        case .success: finish()
        case let .failure(message): showError(message)
        case .needsConsumeConfirmation: break
        }
    }

    private func confirmDelete() {
        guard case .edit = mode else { return }
        let alert = UIAlertController(title: "刪除這筆食材？", message: "刪除後無法復原。若已吃完，建議改用「標記為已食用」。",
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "刪除", style: .destructive) { [weak self] _ in
            guard let self else { return }
            switch self.submitDelete() {
            case .success: self.finish()
            case let .failure(message): self.showError(message)
            case .needsConsumeConfirmation: break
            }
        })
        present(alert, animated: true)
    }

    private func showError(_ message: String) {
        errorLabel.text = message
        errorLabel.isHidden = false
        scrollView.setContentOffset(.zero, animated: true)
        UIAccessibility.post(notification: .announcement, argument: message)
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }

    // MARK: - Styling helpers

    private func section(_ title: String, _ content: UIView) -> UIView {
        let label = UILabel()
        label.text = title
        label.font = Theme.Font.caption
        label.textColor = Theme.Color.textSecondary
        let section = UIStackView(arrangedSubviews: [label, content])
        section.axis = .vertical
        section.spacing = 6
        return section
    }

    private func leadingRow(_ views: [UIView]) -> UIStackView {
        let row = UIStackView(arrangedSubviews: views + (views.contains { type(of: $0) == UIView.self } ? [] : [UIView()]))
        row.spacing = 10
        row.alignment = .center
        return row
    }

    private func styleField(_ field: UITextField, placeholder: String) {
        field.placeholder = placeholder
        field.font = Theme.Font.body
        field.textColor = Theme.Color.textPrimary
        field.backgroundColor = Theme.Color.interior
        field.layer.cornerRadius = 8
        field.layer.borderWidth = Theme.Metric.strokeWidth
        field.layer.borderColor = Theme.Color.divider.cgColor
        field.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 10, height: 10))
        field.leftViewMode = .always
        field.heightAnchor.constraint(equalToConstant: 42).isActive = true
    }

    private func setMenuButton(_ button: UIButton, title: String, color: UIColor, image: UIImage?) {
        var config = button.configuration ?? .plain()
        config.title = title
        config.baseForegroundColor = color
        config.image = image
        button.configuration = config
    }

    private func styleMenuButton(_ button: UIButton) {
        var config = UIButton.Configuration.plain()
        config.baseForegroundColor = Theme.Color.textPrimary
        config.imagePadding = 8
        config.indicator = .popup
        config.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12)
        button.configuration = config
        button.contentHorizontalAlignment = .leading
        button.showsMenuAsPrimaryAction = true
        button.backgroundColor = Theme.Color.interior
        button.layer.cornerRadius = 8
        button.layer.borderWidth = Theme.Metric.strokeWidth
        button.layer.borderColor = Theme.Color.divider.cgColor
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 42).isActive = true
    }
}
