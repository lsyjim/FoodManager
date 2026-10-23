import CloudKit
import Foundation
import os

/// Syncs `Shared.store` with the shared-fridge zones (Phase 5D): one `CKSyncEngine` for the owner's custom zones in
/// the private database and one for the shared database. It never touches the default zone that SwiftData mirrors.
///
/// Created only through `make(policy:mode:...)`, which returns nil unless sharing is active, the app uses persistent
/// storage and iCloud sync is on — Release 1.0 never starts it. Logs never contain share URLs, tokens, user record
/// names or record contents.
final class SharedSyncEngine: CKSyncEngineDelegate, @unchecked Sendable {
    let store: SharedStore
    private let container: CKContainer
    private var engines: [SharedDatabaseScope: CKSyncEngine] = [:]
    private let logger = Logger(subsystem: "FoodManager.HowCode", category: "SharedSync")
    /// Called on the main queue after fetched changes were applied (UI refresh, notifications, widgets).
    var onChange: (() -> Void)?

    init(store: SharedStore, container: CKContainer) {
        self.store = store
        self.container = container
    }

    static func make(policy: SharingPolicy, mode: PersistenceMode, cloudSyncEnabled: Bool,
                     storeFactory: () throws -> SharedStore = { SharedStore(container: try SharedStore.makeContainer()) }) -> SharedSyncEngine? {
        guard policy.isActive, mode == .persistent, cloudSyncEnabled, let store = try? storeFactory() else { return nil }
        return SharedSyncEngine(store: store, container: CKContainer(identifier: CloudSyncConstants.containerIdentifier))
    }

    func start() {
        guard engines.isEmpty else { return }
        for scope in [SharedDatabaseScope.private, .shared] {
            let database = scope == .private ? container.privateCloudDatabase : container.sharedCloudDatabase
            let saved = (try? store.syncState(scope: scope.rawValue))
                .flatMap { try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: $0) }
            engines[scope] = CKSyncEngine(CKSyncEngine.Configuration(database: database, stateSerialization: saved, delegate: self))
        }
    }

    // MARK: Queueing

    /// Owner: creates both zones of a fridge that is being shared.
    func queueZones(for fridgeID: UUID) {
        engines[.private]?.state.add(pendingDatabaseChanges: [
            .saveZone(CKRecordZone(zoneID: SharedZone.id(fridgeID: fridgeID, kind: .structure))),
            .saveZone(CKRecordZone(zoneID: SharedZone.id(fridgeID: fridgeID, kind: .inventory)))
        ])
    }

    /// Owner: removes both zones (rolling back a conversion that didn't complete).
    func queueZoneDeletion(for fridgeID: UUID) {
        engines[.private]?.state.add(pendingDatabaseChanges: [
            .deleteZone(SharedZone.id(fridgeID: fridgeID, kind: .structure)),
            .deleteZone(SharedZone.id(fridgeID: fridgeID, kind: .inventory))
        ])
    }

    /// Feeds local edits from `SharedInventory` to the right engine.
    func enqueue(_ change: SharedInventory.Change) {
        queueDelete(change.deletes, scope: change.scope)
        queueSave(change.saves, scope: change.scope)
    }

    var isRunning: Bool { !engines.isEmpty }

    /// Sends pending changes of one database now (and waits for the server's answer).
    func sendChanges(scope: SharedDatabaseScope) async throws {
        guard let engine = engines[scope] else { throw SharingServiceError.syncUnavailable }
        try await engine.sendChanges()
    }

    var privateDatabase: CKDatabase { container.privateCloudDatabase }
    var cloudContainer: CKContainer { container }

    func queueSave(_ recordIDs: [CKRecord.ID], scope: SharedDatabaseScope) {
        engines[scope]?.state.add(pendingRecordZoneChanges: recordIDs.map { .saveRecord($0) })
    }

    func queueDelete(_ recordIDs: [CKRecord.ID], scope: SharedDatabaseScope) {
        engines[scope]?.state.add(pendingRecordZoneChanges: recordIDs.map { .deleteRecord($0) })
    }

    /// One explicit fetch of both databases (used by the foreground fallback; `SharedFetchScheduler` keeps calls from
    /// overlapping).
    func fetchChanges() async throws {
        for engine in engines.values {
            try await engine.fetchChanges()
        }
    }

    // MARK: CKSyncEngineDelegate

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        guard let scope = scope(of: syncEngine) else { return }
        do {
            switch event {
            case let .stateUpdate(update):
                try store.saveSyncState(try JSONEncoder().encode(update.stateSerialization), scope: scope.rawValue)

            case let .accountChange(change):
                switch change.changeType {
                case .signIn:
                    break
                case .signOut, .switchAccounts:
                    // The previous account's shared data must not stay on this device; the server keeps the truth.
                    try store.purgeAll(role: scope.role)
                    try store.saveSyncState(nil, scope: scope.rawValue)
                    notifyChange()
                @unknown default:
                    break
                }

            case let .fetchedDatabaseChanges(changes):
                for deletion in changes.deletions {
                    try store.zoneWasDeleted(deletion.zoneID, scope: scope)
                }
                if !changes.deletions.isEmpty { notifyChange() }

            case let .fetchedRecordZoneChanges(changes):
                let report = try store.apply(modifications: changes.modifications.map(\.record),
                                             deletions: changes.deletions.map { ($0.recordID, $0.recordType) }, scope: scope)
                if report.ignored > 0 { logger.notice("Ignored \(report.ignored) invalid shared record(s)") }
                if report.applied + report.deleted > 0 || !changes.modifications.isEmpty { notifyChange() }

            case let .sentRecordZoneChanges(sent):
                for record in sent.savedRecords { try store.didSave(record) }
                try handleFailedSaves(sent.failedRecordSaves, engine: syncEngine, scope: scope)

            case .sentDatabaseChanges, .willFetchChanges, .willFetchRecordZoneChanges, .didFetchRecordZoneChanges,
                 .didFetchChanges, .willSendChanges, .didSendChanges:
                break

            @unknown default:
                break
            }
        } catch {
            logger.error("Shared sync event failed: \(String(describing: type(of: error)), privacy: .public)")
        }
    }

    func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext,
                                   syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        guard let scope = scope(of: syncEngine) else { return nil }
        let pending = syncEngine.state.pendingRecordZoneChanges.filter { context.options.scope.contains($0) }
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) { [store] recordID in
            try? store.outgoingRecord(for: recordID, scope: scope)
        }
    }

    // MARK: Conflicts and failures

    private func handleFailedSaves(_ failures: [CKSyncEngine.Event.SentRecordZoneChanges.FailedRecordSave],
                                   engine: CKSyncEngine, scope: SharedDatabaseScope) throws {
        for failure in failures {
            let recordID = failure.record.recordID
            switch failure.error.code {
            case .serverRecordChanged:
                guard let server = failure.error.serverRecord else { continue }
                if server.recordType == SharedRecordType.food, let id = UUID(uuidString: recordID.recordName),
                   let localUpdatedAt = try store.foodUpdatedAt(id), let serverUpdatedAt = server["updatedAt"] as? Date,
                   localUpdatedAt > serverUpdatedAt {
                    // Local edit is newer: adopt the server's change tag and send it again (quantities are ops, so
                    // only names/dates/compartment follow last-writer-wins).
                    try store.didSave(server)
                    engine.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
                } else {
                    // Server wins (also for immutable ops: the op already exists).
                    try store.apply(modifications: [server], deletions: [], scope: scope)
                }
            case .unknownItem:
                try store.clearSystemFields(recordID: recordID)
                engine.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
            case .zoneNotFound, .userDeletedZone:
                if scope == .private, let zone = SharedZone.parse(recordID.zoneID) {
                    queueZones(for: zone.fridgeID)
                    try store.clearSystemFields(recordID: recordID)
                    engine.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
                } else {
                    try store.zoneWasDeleted(recordID.zoneID, scope: scope)
                    notifyChange()
                }
            case .permissionFailure:
                // A participant tried something only the owner may do (or was removed): drop it; the next fetch
                // restores the server's state.
                engine.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
                logger.notice("Shared record save was refused by the server")
            case .networkFailure, .networkUnavailable, .zoneBusy, .serviceUnavailable, .notAuthenticated,
                 .operationCancelled, .requestRateLimited:
                break // CKSyncEngine retries these on its own.
            default:
                logger.error("Shared record save failed: \(failure.error.code.rawValue, privacy: .public)")
            }
        }
    }

    private func scope(of engine: CKSyncEngine) -> SharedDatabaseScope? {
        switch engine.database.databaseScope {
        case .private: return .private
        case .shared: return .shared
        default: return nil
        }
    }

    private func notifyChange() {
        guard let onChange else { return }
        DispatchQueue.main.async(execute: onChange)
    }
}

/// The foreground fallback fetch: every 30 s, only while a shared fridge is on screen and the app is active. One
/// fetch at a time; failures back off 30 → 60 → 120 → 300 s. Pure state machine (the caller owns the timer).
struct SharedFetchScheduler: Equatable {
    static let baseInterval: TimeInterval = 30
    static let maxInterval: TimeInterval = 300

    private(set) var isFetching = false
    private(set) var consecutiveFailures = 0
    private(set) var lastAttempt: Date?
    var sharedFridgeVisible = false
    var appActive = false

    var currentInterval: TimeInterval {
        min(Self.baseInterval * pow(2, Double(consecutiveFailures)), Self.maxInterval)
    }

    /// Whether a fetch should start now. When true, the fetch is marked in flight.
    mutating func beginIfDue(now: Date) -> Bool {
        guard sharedFridgeVisible, appActive, !isFetching else { return false }
        if let lastAttempt, now.timeIntervalSince(lastAttempt) < currentInterval, now >= lastAttempt { return false }
        isFetching = true
        lastAttempt = now
        return true
    }

    mutating func finish(success: Bool) {
        isFetching = false
        consecutiveFailures = success ? 0 : min(consecutiveFailures + 1, 10)
    }
}

/// Drives `SharedFetchScheduler` with a timer on the main thread. Push notifications stay the main signal; this only
/// covers missed pushes while a shared fridge is on screen.
@MainActor
final class SharedFetchPoller {
    static let tick: TimeInterval = 5
    private(set) var scheduler = SharedFetchScheduler()
    private var timer: Timer?
    private let fetch: () async throws -> Void
    private let now: () -> Date

    init(now: @escaping () -> Date = Date.init, fetch: @escaping () async throws -> Void) {
        self.fetch = fetch
        self.now = now
    }

    var isRunning: Bool { timer != nil }

    func update(sharedFridgeVisible: Bool? = nil, appActive: Bool? = nil) {
        if let sharedFridgeVisible { scheduler.sharedFridgeVisible = sharedFridgeVisible }
        if let appActive { scheduler.appActive = appActive }
        if scheduler.sharedFridgeVisible && scheduler.appActive {
            if timer == nil {
                timer = Timer.scheduledTimer(withTimeInterval: Self.tick, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.tickNow() }
                }
            }
            tickNow()
        } else {
            timer?.invalidate()
            timer = nil
        }
    }

    /// One scheduler check (the timer calls this; tests call it directly).
    func tickNow() {
        guard scheduler.beginIfDue(now: now()) else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.fetch()
                self.scheduler.finish(success: true)
            } catch {
                self.scheduler.finish(success: false)
            }
        }
    }
}
