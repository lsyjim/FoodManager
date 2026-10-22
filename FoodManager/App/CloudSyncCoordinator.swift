import CloudKit
import SwiftData
import UIKit
import os

extension Notification.Name {
    /// The user turned iCloud sync on or off (storage is reopened).
    static let cloudSyncSettingDidChange = Notification.Name("CloudSyncSettingDidChange")
}

/// Runs iCloud sync around the UI: account checks (policy A), refreshing the screens after imports, rolling
/// protection snapshots and preference sync. Only for the persistent store; tests and UI tests never sync.
final class CloudSyncCoordinator {
    private let settings: CloudSyncSettings
    private let monitor: CloudSyncMonitor
    private let snapshots: ProtectionSnapshots
    private let account: CloudAccountProvider
    private let logger = Logger(subsystem: "FoodManager.HowCode", category: "CloudSync")

    /// The session currently shown.
    var currentSession: () -> AppSession? = { nil }
    /// Whether the home screen can be rebuilt now without interrupting the user.
    var canRefresh: () -> Bool = { false }
    /// Rebuilds the screens from storage (fresh contexts on the same container).
    var refresh: (AppSession) -> Void = { _ in }
    /// Shows the account-change explanation (once).
    var presentAccountNotice: () -> Void = {}

    private var preferences: PreferenceCloudSync?
    private var observers: [NSObjectProtocol] = []
    private var importWork: DispatchWorkItem?
    private var baselineWork: DispatchWorkItem?
    private var retryTimer: Timer?
    /// Fingerprint of the data the screens show (updated after local saves and refreshes).
    private var baseline: String?
    private var cloudActive = false
    /// The account check finished in this run (rolling snapshots are only written after it, so one account's
    /// data is never saved under another account's name).
    private var verifiedAccount: String?
    private var accountCheckDone = false

    init(settings: CloudSyncSettings = .shared, monitor: CloudSyncMonitor = .shared, snapshots: ProtectionSnapshots = .shared,
         account: CloudAccountProvider = CloudKitAccountProvider()) {
        self.settings = settings
        self.monitor = monitor
        self.snapshots = snapshots
        self.account = account
    }

    /// Called after storage opened.
    func didOpen(cloudActive: Bool, problem: String?) {
        stop()
        self.cloudActive = cloudActive
        monitor.configure(cloudActive: cloudActive, preparationProblem: problem)
        updateBaseline()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .cloudDataDidImport, object: nil, queue: .main) { [weak self] _ in
            self?.scheduleImportCheck()
        })
        observers.append(center.addObserver(forName: ModelContext.didSave, object: nil, queue: .main) { [weak self] _ in
            self?.scheduleBaselineUpdate()
        })
        observers.append(center.addObserver(forName: .CKAccountChanged, object: nil, queue: .main) { [weak self] _ in
            self?.checkAccount()
        })
        guard settings.isEnabled else {
            monitor.updateAccount(.unknown)
            return
        }
        if cloudActive {
            // Photos saved as files only (e.g. recovered later) get synced records; idempotent.
            _ = try? currentSession()?.magnets.backfillImageRecords()
            let preferences = PreferenceCloudSync(cloud: NSUbiquitousKeyValueStore.default, defaults: .standard)
            preferences.start()
            self.preferences = preferences
        }
        checkAccount()
    }

    func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        preferences?.stop()
        preferences = nil
        retryTimer?.invalidate()
        retryTimer = nil
    }

    // MARK: Account (policy A)

    func checkAccount() {
        Task { @MainActor in
            let state = await account.accountState()
            monitor.updateAccount(state)
            let current = state.isAvailable ? await account.accountFingerprint() : nil
            apply(CloudAccountTransition.evaluate(stored: settings.accountFingerprint, current: current, state: state))
        }
    }

    func apply(_ transition: CloudAccountTransition) {
        accountCheckDone = true
        switch transition {
        case let .firstAccount(id):
            settings.accountFingerprint = id
            verifiedAccount = id
        case .sameAccount:
            verifiedAccount = settings.accountFingerprint
        case let .accountChanged(id):
            // iOS swaps the synced data for the new account's. The previous account's data is in its snapshot.
            settings.accountFingerprint = id
            settings.protectionFingerprint = nil
            verifiedAccount = id
            settings.hasPendingAccountNotice = true
            presentAccountNotice()
        case .unavailable:
            verifiedAccount = nil
        }
    }

    // MARK: Protection snapshots

    /// Keeps the rolling local copy current (on entering the background).
    func refreshProtectionSnapshot() {
        guard settings.isEnabled, accountCheckDone, let session = currentSession(), session.mode == .persistent else { return }
        snapshots.refresh(using: session.makeBackupService(), settings: settings, account: verifiedAccount)
    }

    // MARK: Imports → UI

    private func scheduleImportCheck() {
        importWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.checkImportedData() }
        importWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    /// Settles imported data and refreshes the screens only if something actually changed.
    func checkImportedData() {
        guard let session = currentSession() else { return }
        let reconciler = SyncReconciler(container: session.container)
        _ = try? reconciler.run()
        guard let fingerprint = try? reconciler.fingerprint(), fingerprint != baseline else { return }
        refreshWhenIdle()
    }

    private func refreshWhenIdle() {
        retryTimer?.invalidate()
        retryTimer = nil
        guard let session = currentSession() else { return }
        if canRefresh() {
            refresh(session)
            updateBaseline()
        } else {
            // The user is editing or looking at a sheet: try again shortly, never interrupt.
            retryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { [weak self] _ in self?.refreshWhenIdle() }
        }
    }

    private func scheduleBaselineUpdate() {
        baselineWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.updateBaseline() }
        baselineWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func updateBaseline() {
        guard let session = currentSession() else { return }
        baseline = try? SyncReconciler(container: session.container).fingerprint()
    }
}
