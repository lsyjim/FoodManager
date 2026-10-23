import UIKit

/// Owner's view of a shared fridge (Phase 5D-3): pending access requests, members, blocked people, whether new
/// requests are accepted, the invitation link and stopping sharing. Shows only what the server returned; every
/// action is saved on the server first and the list is fetched again afterwards.
final class SharedMembersViewController: UITableViewController {
    private enum Section: Int, CaseIterable { case requests, members, blocked, settings }
    private enum SettingsRow: Int, CaseIterable { case allowRequests, invite, stop }

    private let sharing: SharingService
    private let fridgeID: UUID
    private let fridgeName: String
    /// Sharing stopped: the management screen reloads.
    var onSharingStopped: (() -> Void)?
    private var overview: ShareOverview?
    private var loadError: String?
    private var isBusy = false

    init(sharing: SharingService, fridgeID: UUID, fridgeName: String) {
        self.sharing = sharing
        self.fridgeID = fridgeID
        self.fridgeName = fridgeName
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "成員與申請"
        view.accessibilityIdentifier = "sharedMembers"
        tableView.backgroundColor = Theme.Color.background
        refreshControl = UIRefreshControl()
        refreshControl?.addTarget(self, action: #selector(load), for: .valueChanged)
        load()
    }

    @objc private func load() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                self.overview = try await self.sharing.shareOverview(fridgeID: self.fridgeID)
                self.loadError = nil
            } catch {
                self.loadError = Self.message(for: error)
            }
            self.refreshControl?.endRefreshing()
            self.tableView.reloadData()
        }
    }

    // MARK: Table

    override func numberOfSections(in tableView: UITableView) -> Int { Section.allCases.count }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch Section(rawValue: section)! {
        case .requests: return max(overview?.requesters.count ?? 0, 1)
        case .members: return max(overview?.members.count ?? 0, 1)
        case .blocked: return overview?.blocked.count ?? 0
        case .settings: return SettingsRow.allCases.count
        }
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch Section(rawValue: section)! {
        case .requests: return "等待你同意"
        case .members: return "成員"
        case .blocked: return (overview?.blocked.isEmpty ?? true) ? nil : "已封鎖"
        case .settings: return nil
        }
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch Section(rawValue: section)! {
        case .requests: return loadError ?? "收到邀請連結的人要先送出申請，你同意後才看得到這台冰箱。"
        case .members: return "成員可以新增、編輯和取用食材；冰箱名稱、隔層與磁鐵只有你能修改。"
        case .settings: return "停止共享後，所有成員會立即失去存取權，冰箱與食材仍保留在你這裡。"
        case .blocked: return nil
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.backgroundColor = Theme.Color.interior
        var content = cell.defaultContentConfiguration()
        content.secondaryTextProperties.color = Theme.Color.textSecondary
        switch Section(rawValue: indexPath.section)! {
        case .requests:
            if let person = overview?.requesters[safe: indexPath.row] {
                content.text = person.name
                content.secondaryText = person.contactDetail
                content.image = UIImage(systemName: "person.crop.circle.badge.questionmark")
                cell.accessibilityIdentifier = "sharedMembers.request"
            } else {
                content.text = overview == nil ? "讀取中…" : "目前沒有申請"
                content.textProperties.color = Theme.Color.textSecondary
                cell.selectionStyle = .none
            }
        case .members:
            if let person = overview?.members[safe: indexPath.row] {
                content.text = person.name
                content.image = UIImage(systemName: "person.crop.circle")
                cell.accessibilityIdentifier = "sharedMembers.member"
            } else {
                content.text = overview == nil ? "讀取中…" : "還沒有成員"
                content.textProperties.color = Theme.Color.textSecondary
                cell.selectionStyle = .none
            }
        case .blocked:
            let person = overview?.blocked[indexPath.row]
            content.text = person?.name
            content.image = UIImage(systemName: "hand.raised")
        case .settings:
            switch SettingsRow(rawValue: indexPath.row)! {
            case .allowRequests:
                content.text = "允許新的加入申請"
                let toggle = UISwitch()
                toggle.isOn = overview?.allowsAccessRequests ?? true
                toggle.isEnabled = overview != nil
                toggle.accessibilityIdentifier = "sharedMembers.allowRequests"
                toggle.addTarget(self, action: #selector(allowRequestsChanged(_:)), for: .valueChanged)
                cell.accessoryView = toggle
                cell.selectionStyle = .none
            case .invite:
                content.text = "分享邀請連結"
                content.image = UIImage(systemName: "square.and.arrow.up")
            case .stop:
                content.text = "停止共享"
                content.textProperties.color = Theme.Color.destructive
                cell.accessibilityIdentifier = "sharedMembers.stop"
            }
        }
        content.imageProperties.tintColor = Theme.Color.stroke
        cell.contentConfiguration = content
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard !isBusy else { return }
        let source = tableView.cellForRow(at: indexPath)
        switch Section(rawValue: indexPath.section)! {
        case .requests:
            guard let person = overview?.requesters[safe: indexPath.row] else { return }
            let sheet = UIAlertController(title: person.name, message: "想加入「\(fridgeName)」", preferredStyle: .actionSheet)
            sheet.addAction(UIAlertAction(title: "同意加入", style: .default) { [weak self] _ in
                self?.perform("已同意加入") { try await $0.approve(person, fridgeID: $1) }
            })
            sheet.addAction(UIAlertAction(title: "拒絕", style: .default) { [weak self] _ in
                self?.perform("已拒絕") { try await $0.deny(person, fridgeID: $1) }
            })
            sheet.addAction(UIAlertAction(title: "封鎖（不能再申請）", style: .destructive) { [weak self] _ in
                self?.perform("已封鎖") { try await $0.block(person, fridgeID: $1) }
            })
            present(sheet, from: source)
        case .members:
            guard let person = overview?.members[safe: indexPath.row] else { return }
            let sheet = UIAlertController(title: person.name, message: "移除後，對方會立即看不到這台冰箱。", preferredStyle: .actionSheet)
            sheet.addAction(UIAlertAction(title: "移除成員", style: .destructive) { [weak self] _ in
                self?.perform("已移除") { try await $0.remove(person, fridgeID: $1) }
            })
            present(sheet, from: source)
        case .blocked:
            guard let person = overview?.blocked[safe: indexPath.row] else { return }
            let sheet = UIAlertController(title: person.name, message: nil, preferredStyle: .actionSheet)
            sheet.addAction(UIAlertAction(title: "解除封鎖", style: .default) { [weak self] _ in
                self?.perform("已解除封鎖") { try await $0.unblock(person, fridgeID: $1) }
            })
            present(sheet, from: source)
        case .settings:
            switch SettingsRow(rawValue: indexPath.row)! {
            case .allowRequests: break
            case .invite: presentInvitation(from: source)
            case .stop: confirmStop()
            }
        }
    }

    // MARK: Actions

    @objc private func allowRequestsChanged(_ toggle: UISwitch) {
        let allowed = toggle.isOn
        perform(allowed ? "已開放加入申請" : "已停止接受新的申請") { try await $0.setAllowsAccessRequests(allowed, fridgeID: $1) }
    }

    private func presentInvitation(from source: UIView?) {
        guard let url = sharing.invitationURL(for: fridgeID) else { return }
        let text = "邀請你一起管理「\(fridgeName)」冰箱。開啟連結後送出申請，我同意後就能加入："
        let activity = UIActivityViewController(activityItems: [text, url], applicationActivities: nil)
        activity.popoverPresentationController?.sourceView = source ?? view
        present(activity, animated: true)
    }

    private func confirmStop() {
        let alert = UIAlertController(title: "停止共享「\(fridgeName)」？",
                                      message: "所有成員會立即失去存取權，邀請連結也會失效。冰箱、食材與磁鐵都會保留在你這裡。",
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "停止共享", style: .destructive) { [weak self] _ in
            guard let self else { return }
            self.perform(nil) { try await $0.stopSharing(fridgeID: $1) } done: { [weak self] in
                self?.onSharingStopped?()
                self?.navigationController?.popViewController(animated: true)
            }
        })
        present(alert, animated: true)
    }

    /// Runs one server action, then reloads. Nothing is shown as done before the server confirmed it.
    private func perform(_ success: String?, _ action: @escaping (SharingService, UUID) async throws -> Void,
                         done: (() -> Void)? = nil) {
        isBusy = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await action(self.sharing, self.fridgeID)
                self.isBusy = false
                if let success { self.showToast(success) }
                if let done { done() } else { self.load() }
            } catch {
                self.isBusy = false
                FoodActions.showError(Self.message(for: error), on: self)
                self.load()
            }
        }
    }

    private func showToast(_ text: String) {
        let alert = UIAlertController(title: nil, message: text, preferredStyle: .alert)
        present(alert, animated: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak alert] in alert?.dismiss(animated: true) }
    }

    private func present(_ sheet: UIAlertController, from source: UIView?) {
        sheet.addAction(UIAlertAction(title: "取消", style: .cancel))
        sheet.popoverPresentationController?.sourceView = source ?? view
        present(sheet, animated: true)
    }

    private static func message(for error: Error) -> String {
        (error as? ShareAdministrationError)?.message ?? (error as? SharingServiceError)?.message
            ?? (error as? SharedStoreError)?.message ?? ShareAdministrationError.serverFailure.message
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
