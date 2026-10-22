import CoreData
import Foundation
import SwiftData

extension Notification.Name {
    static let cloudSyncStatusDidChange = Notification.Name("CloudSyncStatusDidChange")
    /// An iCloud import finished; synced data may have changed.
    static let cloudDataDidImport = Notification.Name("CloudDataDidImport")
}

/// What 設定 shows. Only states the system actually reports: there is no "已同步" (CloudKit doesn't tell us
/// that every device has every change), and no invented sync time.
enum CloudSyncStatus: Equatable {
    case off
    case unavailable(CloudAccountState)
    case available
    /// Local changes saved after the last successful upload.
    case pending
    /// An import / export / setup is running right now (reported by NSPersistentCloudKitContainer).
    case syncing
    case problem(String)

    var title: String {
        switch self {
        case .off: return "已關閉"
        case .unavailable: return "iCloud 無法使用"
        case .available: return "iCloud 可使用"
        case .pending: return "等待同步"
        case .syncing: return "同步中"
        case .problem: return "同步發生問題"
        }
    }

    var detail: String? {
        switch self {
        case .off: return "資料只保存在這台裝置上。"
        case let .unavailable(state):
            switch state {
            case .noAccount: return "這台裝置沒有登入 iCloud。到「設定」App 登入 Apple 帳號並開啟 iCloud 後就會自動同步。資料仍保存在這台裝置上。"
            case .restricted: return "iCloud 被限制使用（例如螢幕使用時間或管理描述檔）。資料仍保存在這台裝置上。"
            case .temporarilyUnavailable: return "iCloud 暫時無法使用，稍後會自動重試。資料仍保存在這台裝置上。"
            default: return "目前無法確認 iCloud 狀態，稍後會自動重試。資料仍保存在這台裝置上。"
            }
        case .available: return nil
        case .pending: return "這台裝置有變更還沒上傳到 iCloud，網路與系統允許時會自動上傳。"
        case .syncing: return nil
        case let .problem(message): return message
        }
    }
}

/// Derives `CloudSyncStatus` from NSPersistentCloudKitContainer events, local saves and the account state.
final class CloudSyncMonitor {
    static let shared = CloudSyncMonitor()

    private(set) var isCloudActive = false
    private(set) var accountState: CloudAccountState = .unknown
    private(set) var preparationProblem: String?
    private(set) var lastLocalSave: Date?
    private(set) var lastSuccessfulExport: Date?
    /// When CloudKit last completed an import or export successfully (from the event's end date).
    private(set) var lastSuccess: Date?
    private var running: Set<UUID> = []
    private var lastFailure: String?
    private var observers: [NSObjectProtocol] = []
    private let now: () -> Date

    init(center: NotificationCenter = .default, now: @escaping () -> Date = Date.init) {
        self.now = now
        observers.append(center.addObserver(forName: NSPersistentCloudKitContainer.eventChangedNotification, object: nil, queue: .main) { [weak self] note in
            guard let event = note.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey] as? NSPersistentCloudKitContainer.Event else { return }
            self?.handle(EventInfo(event))
        })
        observers.append(center.addObserver(forName: ModelContext.didSave, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.lastLocalSave = self.now()
            self.post()
        })
    }

    struct EventInfo {
        enum Kind { case setup, importing, exporting }
        let id: UUID
        let kind: Kind
        let ended: Date?
        let succeeded: Bool
        let errorDescription: String?

        init(id: UUID, kind: Kind, ended: Date?, succeeded: Bool, errorDescription: String? = nil) {
            self.id = id
            self.kind = kind
            self.ended = ended
            self.succeeded = succeeded
            self.errorDescription = errorDescription
        }

        init(_ event: NSPersistentCloudKitContainer.Event) {
            id = event.identifier
            switch event.type {
            case .setup: kind = .setup
            case .import: kind = .importing
            default: kind = .exporting
            }
            ended = event.endDate
            succeeded = event.succeeded
            errorDescription = event.error.map { _ in "iCloud 回報錯誤，系統稍後會自動重試。若持續發生，請確認 iCloud 空間是否足夠。" }
        }
    }

    func configure(cloudActive: Bool, preparationProblem: String?) {
        isCloudActive = cloudActive
        self.preparationProblem = preparationProblem
        running.removeAll()
        post()
    }

    func updateAccount(_ state: CloudAccountState) {
        accountState = state
        post()
    }

    func handle(_ event: EventInfo) {
        guard let ended = event.ended else {
            running.insert(event.id)
            post()
            return
        }
        running.remove(event.id)
        if event.succeeded {
            lastFailure = nil
            lastSuccess = ended
            if event.kind == .exporting { lastSuccessfulExport = ended }
            if event.kind == .importing { NotificationCenter.default.post(name: .cloudDataDidImport, object: self) }
        } else {
            lastFailure = event.errorDescription ?? "同步沒有完成，系統稍後會自動重試。"
        }
        post()
    }

    func status(enabled: Bool) -> CloudSyncStatus {
        guard enabled else { return .off }
        if let preparationProblem { return .problem(preparationProblem) }
        guard accountState.isAvailable else { return .unavailable(accountState) }
        guard isCloudActive else { return .problem("iCloud 同步會在下次開啟 App 時啟用。") }
        if !running.isEmpty { return .syncing }
        if let lastFailure { return .problem(lastFailure) }
        if let lastLocalSave, lastLocalSave > (lastSuccessfulExport ?? .distantPast) { return .pending }
        return .available
    }

    private func post() {
        NotificationCenter.default.post(name: .cloudSyncStatusDidChange, object: self)
    }
}
