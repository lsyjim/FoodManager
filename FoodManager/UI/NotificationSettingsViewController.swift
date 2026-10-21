import UIKit

/// Notification preferences and permission status. Food management works regardless of what is chosen here.
final class NotificationSettingsViewController: UITableViewController {
    private enum Row {
        case status, permissionAction, expirationToggle, storageToggle, time, leadDays
    }

    private let coordinator: NotificationCoordinator
    private var preferences: NotificationPreferences
    private var authorization: NotificationAuthorization = .notDetermined
    private var sections: [[Row]] = []

    init(coordinator: NotificationCoordinator) {
        self.coordinator = coordinator
        preferences = coordinator.preferences
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "通知設定"
        tableView.backgroundColor = Theme.Color.background
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        NotificationCenter.default.addObserver(self, selector: #selector(refreshAuthorization),
                                               name: UIApplication.didBecomeActiveNotification, object: nil)
        rebuild()
        refreshAuthorization()
    }

    @objc private func refreshAuthorization() {
        Task { @MainActor in
            authorization = await coordinator.authorizationStatus()
            rebuild()
        }
    }

    private func rebuild() {
        sections = [
            authorization == .authorized || authorization == .provisional || authorization == .ephemeral
                ? [.status] : [.status, .permissionAction],
            [.expirationToggle, .storageToggle],
            [.time, .leadDays],
        ]
        tableView.reloadData()
    }

    private func save() {
        coordinator.preferencesStore.save(preferences)
        coordinator.scheduleUpdate()
    }

    // MARK: - Table

    override func numberOfSections(in tableView: UITableView) -> Int { sections.count }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { sections[section].count }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        ["通知權限", "提醒類型", "時間"][section]
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch section {
        case 0:
            switch authorization {
            case .denied: return "通知已在系統中關閉。你仍可在 App 內的「食材提醒」查看所有提醒；若要收到通知，請到「設定」開啟。"
            case .notDetermined: return "開啟後，會在食材快到期或存放到你設定的天數時通知你。"
            default: return nil
            }
        case 1: return "只有設定了到期日的食材才會有到期通知；保存提醒依你在每項食材設定的天數，兩者互不影響。已經過期或已到期的保存提醒不會另外通知，請在「食材提醒」查看。"
        default: return "通知依你所在地的日曆與時間計算，夏令時間變動時仍在設定的時間送出。"
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
        cell.backgroundColor = Theme.Color.interior
        cell.selectionStyle = .none
        cell.accessoryView = nil
        var content = cell.defaultContentConfiguration()
        switch sections[indexPath.section][indexPath.row] {
        case .status:
            content.text = "通知"
            content.secondaryText = statusText
        case .permissionAction:
            content.text = authorization == .denied ? "前往「設定」開啟通知" : "開啟通知"
            content.textProperties.color = Theme.Color.stroke
            cell.selectionStyle = .default
            cell.accessibilityTraits = .button
        case .expirationToggle:
            content.text = "到期提醒"
            cell.accessoryView = makeSwitch(isOn: preferences.expirationRemindersEnabled) { [weak self] in
                self?.preferences.expirationRemindersEnabled = $0
                self?.save()
            }
        case .storageToggle:
            content.text = "保存提醒"
            cell.accessoryView = makeSwitch(isOn: preferences.storageRemindersEnabled) { [weak self] in
                self?.preferences.storageRemindersEnabled = $0
                self?.save()
            }
        case .time:
            content.text = "提醒時間"
            let picker = UIDatePicker()
            picker.datePickerMode = .time
            picker.preferredDatePickerStyle = .compact
            picker.date = Calendar.current.date(bySettingHour: preferences.reminderHour, minute: preferences.reminderMinute,
                                                second: 0, of: Date()) ?? Date()
            picker.accessibilityLabel = "每日提醒時間"
            picker.addAction(UIAction { [weak self, weak picker] _ in
                guard let self, let picker else { return }
                let parts = Calendar.current.dateComponents([.hour, .minute], from: picker.date)
                self.preferences.reminderHour = parts.hour ?? 9
                self.preferences.reminderMinute = parts.minute ?? 0
                self.save()
            }, for: .valueChanged)
            cell.accessoryView = picker
            picker.sizeToFit()
        case .leadDays:
            content.text = "到期通知"
            content.secondaryText = leadText
            let stepper = UIStepper()
            stepper.minimumValue = Double(NotificationPreferences.leadDayRange.lowerBound)
            stepper.maximumValue = Double(NotificationPreferences.leadDayRange.upperBound)
            stepper.value = Double(preferences.expirationLeadDays)
            stepper.accessibilityLabel = "到期前幾天通知"
            stepper.addAction(UIAction { [weak self, weak stepper] _ in
                guard let self, let stepper else { return }
                self.preferences.expirationLeadDays = Int(stepper.value)
                self.save()
                self.tableView.reloadRows(at: [indexPath], with: .none)
            }, for: .valueChanged)
            cell.accessoryView = stepper
        }
        content.textProperties.font = UIFont.preferredFont(forTextStyle: .body)
        content.secondaryTextProperties.font = UIFont.preferredFont(forTextStyle: .body)
        cell.contentConfiguration = content
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard sections[indexPath.section][indexPath.row] == .permissionAction else { return }
        if authorization == .denied {
            if let url = URL(string: UIApplication.openNotificationSettingsURLString) { UIApplication.shared.open(url) }
        } else {
            Task { @MainActor in
                authorization = await coordinator.requestAuthorization()
                rebuild()
            }
        }
    }

    private var statusText: String {
        switch authorization {
        case .authorized: return "已開啟"
        case .provisional: return "已開啟（安靜送達）"
        case .ephemeral: return "暫時開啟"
        case .denied: return "已關閉"
        case .notDetermined: return "尚未設定"
        }
    }

    private var leadText: String {
        preferences.expirationLeadDays == 0 ? "到期當天" : "到期前 \(preferences.expirationLeadDays) 天"
    }

    private func makeSwitch(isOn: Bool, onChange: @escaping (Bool) -> Void) -> UISwitch {
        let toggle = UISwitch()
        toggle.isOn = isOn
        toggle.onTintColor = Theme.Color.stroke
        toggle.addAction(UIAction { [weak toggle] _ in onChange(toggle?.isOn ?? false) }, for: .valueChanged)
        return toggle
    }
}
