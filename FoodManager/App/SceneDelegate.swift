import CloudKit
import SwiftData
import UIKit

/// Composition root: opens storage, then shows either the fridge or the recoverable storage-error screen.
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private(set) var home: FridgeHomeViewController?
    private lazy var persistence = Self.makePersistence()
    private var currentSession: AppSession?
    /// Native App Store rating prompt (real data only: tests and UI tests never count usage or ask).
    private lazy var review: ReviewRequestCoordinator? = persistence.mode == .persistent ? ReviewRequestCoordinator() : nil
    private var reviewCheck: Task<Void, Never>?
    /// Manual iCloud backups (Phase 5E). Personal data never syncs on its own; only real data can be backed up.
    private lazy var icloudBackup: ICloudBackupService? = persistence.mode == .persistent ? ICloudBackupService(store: CloudKitBackupStore()) : nil
    /// Shared refrigerators (Phase 5D): only while `SharingPolicy` is active. Release 1.0 never creates them. They have
    /// their own sync (CKSyncEngine), independent of personal data.
    private var sharedEngine: SharedSyncEngine?
    private var sharedInventory: SharedInventory?
    /// 30-second fallback fetch while a shared fridge is on screen and the app is active.
    private var sharedPoller: SharedFetchPoller?
    /// Built once from `MonetizationPolicy` (survives storage retries and fridge switches).
    private lazy var monetization = MonetizationServices.make(policy: .current, mode: persistence.mode)

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        window.overrideUserInterfaceStyle = .light // fixed warm palette
        window.tintColor = Theme.Color.stroke
        self.window = window
        start()
        window.makeKeyAndVisible()
        review?.recordLaunch()
        NotificationCenter.default.addObserver(forName: .foodItemCreated, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.foodWasCreated() }
        }
        // Cold launch from a widget: delivered once the fridge screen is ready.
        if let url = connectionOptions.urlContexts.first?.url { AppNotificationRouter.shared.handle(url: url) }
    }

    /// Refunds, purchases on other devices or Ask-to-Buy approvals may have happened while in the background.
    func sceneWillEnterForeground(_ scene: UIScene) {
        monetization.ads?.appWillEnterForeground()
        checkSharedInvitations()
        guard let entitlements = monetization.entitlementObserver else { return }
        Task { await entitlements.refresh() }
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        monetization.ads?.appDidEnterBackground()
    }

    /// Widget tap while running or restored from the background.
    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        guard let url = URLContexts.first?.url else { return }
        AppNotificationRouter.shared.handle(url: url)
    }

    /// Someone opened a shared-fridge link. Ignored entirely while sharing is off (never accepted, no paywall);
    /// requesting access as a participant arrives in Phase 5D-4.
    func windowScene(_ windowScene: UIWindowScene, userDidAcceptCloudKitShareWith metadata: CKShare.Metadata) {
        guard SharingPolicy.current.joinGate == .allowed, let sharing = currentSession?.sharing, let url = metadata.share.url else { return }
        openInvitation(url, sharing: sharing)
    }

    /// Joins (if the owner already approved) or sends an access request, and tells the user which.
    private func openInvitation(_ url: URL, sharing: SharingService) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                switch try await sharing.join(url: url) {
                case .joined:
                    self.home?.showMessage("已加入共享冰箱，資料下載中…")
                    self.sharedDataChanged()
                case .alreadyJoined: self.home?.showMessage("你已經是這台冰箱的成員")
                case .ownFridge: self.home?.showMessage("這是你自己共享的冰箱")
                case .waitingForApproval: self.home?.showMessage("已送出加入申請，等待冰箱主人同意")
                }
            } catch {
                let message = (error as? JoinError)?.message ?? (error as? SharingServiceError)?.message ?? "無法開啟這個邀請，請稍後再試。"
                self.home?.showMessage(message)
            }
        }
    }

    /// (Re)attempts to open storage. Called at launch and by the error screen's retry button.
    private func start() {
        switch AppBootstrap.start(persistence, sharing: { [weak self] in self?.makeSharing(container: $0) }) {
        case let .success(session):
            show(session)
            if persistence.mode == .persistent { offerICloudRestoreIfFirstRun() }
        case .failure:
            home = nil
            if let errorScreen = window?.rootViewController as? StorageUnavailableViewController {
                errorScreen.showRetryFailed()
            } else {
                let errorScreen = StorageUnavailableViewController()
                errorScreen.onRetry = { [weak self] in self?.start() }
                window?.rootViewController = errorScreen
            }
        }
    }

    /// Shows the home screen for the session's selected fridge.
    private func show(_ session: AppSession, animated: Bool = false) {
        currentSession = session
        let home = FridgeHomeViewController(session: session, entitlements: monetization.entitlementsForUI, ads: monetization.ads)
        home.onSwitchFridge = { [weak self] id, route in self?.switchFridge(to: id, from: session, then: route) }
        home.onDataRestored = { [weak self] failure in self?.reloadAfterRestore(from: session, failure: failure) }
        home.icloudBackup = icloudBackup
        home.onVisibilityChange = { [weak self] visible, isShared in
            MainActor.assumeIsolated { self?.sharedPoller?.update(sharedFridgeVisible: visible && isShared) }
        }
        self.home = home
        let navigation = UINavigationController(rootViewController: home)
        navigation.navigationBar.tintColor = Theme.Color.stroke
        guard let window else { return }
        window.rootViewController = navigation
        if animated && !UIAccessibility.isReduceMotionEnabled {
            UIView.transition(with: window, duration: 0.25, options: .transitionCrossDissolve, animations: nil)
        }
    }

    /// Selects another fridge (remembered for the next launch) and shows it, then delivers `route` there.
    private func switchFridge(to id: UUID, from session: AppSession, then route: ExternalRoute?) {
        do {
            show(try session.selecting(id), animated: true)
            if let route { AppNotificationRouter.shared.route(route) }
        } catch {
            home?.showMessage("無法切換冰箱，請再試一次。")
        }
    }

    /// A restore replaced the stored data: rebuild everything (fresh contexts on the same container, never a
    /// second one), so no screen keeps showing old data. Then reschedule notifications and refresh widgets.
    private func reloadAfterRestore(from session: AppSession, failure: String?) {
        switch AppBootstrap.makeSession(container: session.container, mode: session.mode, selection: session.selection,
                                         sharing: session.sharing) {
        case let .success(restored):
            show(restored, animated: true)
            guard let home else { return }
            home.loadViewIfNeeded()
            Task { @MainActor [weak home] in
                let problems = await home?.syncAfterRestore() ?? []
                guard let home else { return }
                if let failure {
                    let alert = UIAlertController(title: "沒有還原", message: failure, preferredStyle: .alert)
                    alert.addAction(UIAlertAction(title: "好", style: .default))
                    home.present(alert, animated: true)
                } else if problems.isEmpty {
                    home.showMessage("已還原備份")
                } else {
                    home.showMessage("已還原備份，但\(problems.joined(separator: "與"))暫時沒有更新，稍後會自動再試")
                }
            }
        case .failure:
            // The restored data is saved; only this screen couldn't be rebuilt.
            home?.showMessage("資料已還原，但畫面無法重新載入，請關閉並重新開啟 App")
        }
    }

    /// iCloud delivered changes: rebuild from the same container (fresh contexts) so every screen, the reminder
    /// schedule and the widget snapshots reflect them. Only called while the user isn't in the middle of something.
    private func reloadAfterCloudImport(from session: AppSession) {
        guard case let .success(updated) = AppBootstrap.makeSession(container: session.container, mode: session.mode,
                                                                    selection: session.selection, sharing: session.sharing) else { return }
        show(updated)
    }

    /// The shared-fridge pipeline for an opened container, or nil (sharing off, tests, or iCloud sync not running).
    private func makeSharing(container: ModelContainer) -> SharingService? {
        let policy = SharingPolicy.current
        if sharedEngine == nil {
            // CKSyncEngine follows the iCloud account itself (sign-in / sign-out events).
            sharedEngine = SharedSyncEngine.make(policy: policy, mode: persistence.mode, cloudSyncEnabled: true)
            sharedEngine?.onChange = { [weak self] in self?.sharedDataChanged() }
            sharedEngine?.start()
            if let engine = sharedEngine {
                sharedPoller = MainActor.assumeIsolated {
                    let poller = SharedFetchPoller { [weak engine] in try await engine?.fetchChanges() }
                    poller.update(appActive: UIApplication.shared.applicationState == .active)
                    return poller
                }
            }
        }
        guard let engine = sharedEngine else { return nil }
        let inventory = sharedInventory ?? SharedInventory(store: engine.store)
        inventory.onLocalChange = { [weak engine] change in engine?.enqueue(change) }
        sharedInventory = inventory
        return SharingService(policy: policy, inventory: inventory, cloud: CloudKitSharingCloud(engine: engine),
                              personal: SwiftDataFridgeStore(container: container),
                              hasPremium: { [weak self] in self?.monetization.entitlementObserver?.isPremium ?? false },
                              snapshots: .shared, administrator: Self.makeAdministrator(engine),
                              participantCloud: Self.makeParticipantCloud(engine))
    }

    private static func makeAdministrator(_ engine: SharedSyncEngine) -> ShareAdministering? {
        guard #available(iOS 26.0, *) else { return nil }
        return CloudKitShareAdministrator(container: engine.cloudContainer)
    }

    private static func makeParticipantCloud(_ engine: SharedSyncEngine) -> ParticipantCloud? {
        guard #available(iOS 26.0, *) else { return nil }
        return CloudKitParticipantCloud(container: engine.cloudContainer, engine: engine)
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        MainActor.assumeIsolated { sharedPoller?.update(appActive: true) }
        startWatchingInvitations()
    }

    func sceneWillResignActive(_ scene: UIScene) {
        MainActor.assumeIsolated { sharedPoller?.update(appActive: false) }
        invitationTimer?.invalidate()
        invitationTimer = nil
    }

    /// While an access request waits (or an approved join is still completing) and the app is active, checks every
    /// 15 s, so 「等待主人同意」 turns into the fridge by itself once the owner approves.
    private var invitationTimer: Timer?
    private var isCheckingInvitations = false
    static let invitationCheckInterval: TimeInterval = 15

    private func startWatchingInvitations() {
        guard invitationTimer == nil, currentSession?.sharing != nil else { return }
        invitationTimer = Timer.scheduledTimer(withTimeInterval: Self.invitationCheckInterval, repeats: true) { [weak self] _ in
            self?.checkInvitationsIfWaiting()
        }
    }

    private func checkInvitationsIfWaiting() {
        guard !isCheckingInvitations, let sharing = currentSession?.sharing,
              let waiting = try? sharing.inventory.store.reservedSlots(), waiting > 0 else { return }
        isCheckingInvitations = true
        Task { @MainActor [weak self] in
            _ = await sharing.checkPendingInvitations()
            let stillWaiting = (try? sharing.inventory.store.reservedSlots()) ?? waiting
            self?.isCheckingInvitations = false
            if stillWaiting != waiting { self?.sharedDataChanged() }
        }
    }

    /// Requests the owner approved while the app was away are joined now.
    private func checkSharedInvitations() {
        guard let sharing = currentSession?.sharing else { return }
        Task { @MainActor [weak self] in
            if !(await sharing.checkPendingInvitations()).isEmpty { self?.sharedDataChanged() }
        }
    }

    /// Shared-fridge changes arrived: rebuild like after an iCloud import, at a calm moment only.
    private func sharedDataChanged() {
        // A newly readable inventory may carry the link to its read-only structure share.
        if let sharing = currentSession?.sharing { Task { await sharing.continueStructureJoins() } }
        // Open lists (fridge management) re-read: a waiting request may have turned into a fridge.
        NotificationCenter.default.post(name: .fridgesDidChange, object: nil)
        guard let session = currentSession, home?.canBeRebuilt == true else {
            home?.refreshSharedIntegrations()
            return
        }
        reloadAfterCloudImport(from: session)
    }

    /// A new installation (empty store, no choice made yet): if this iCloud account has personal backups, ask whether
    /// to restore one or start fresh. Only backup metadata is read; nothing is downloaded or restored without the
    /// user's choice and confirmation. If iCloud can't be asked right now, the question stays open (restoring is
    /// always available in 設定) — an unreachable iCloud is never taken for "no backups".
    private func offerICloudRestoreIfFirstRun() {
        guard FirstRunState.load() == .pending, let icloudBackup else { return }
        Task { @MainActor [weak self] in
            guard let versions = try? await icloudBackup.versions() else { return }
            guard let latest = versions.first else { return FirstRunState.decided.save() }
            guard let self, FirstRunState.load() == .pending, let home = self.home else { return }
            let alert = UIAlertController(
                title: "找到 iCloud 冰箱備份",
                message: "你的 iCloud 有 \(versions.count) 份冰箱管理員的備份（最新：\(latest.createdAt.formatted(.dateTime.year().month().day()))，\(latest.fridgeCount) 台冰箱、\(latest.activeFoodCount) 筆食材）。要還原，還是建立新的冰箱？之後也可以在「設定 → iCloud 備份」還原。",
                preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "建立新的冰箱", style: .cancel) { _ in FirstRunState.decided.save() })
            alert.addAction(UIAlertAction(title: "從 iCloud 還原", style: .default) { [weak home] _ in
                FirstRunState.decided.save()
                home?.presentICloudRestore()
            })
            home.present(alert, animated: true)
        }
    }

    /// A food record was saved. Counts it, then — at a calm moment back on the fridge home (editor closed, nothing
    /// on top, no ad nearby) — lets the coordinator decide whether to ask iOS for the rating prompt. Checks a few
    /// times while e.g. a continuous-entry editor is still open, then gives up until the next food is added.
    private func foodWasCreated() {
        guard let review else { return }
        review.recordSuccessfulFoodCreation()
        reviewCheck?.cancel()
        reviewCheck = Task { @MainActor [weak self] in
            for _ in 0..<15 {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled, let self, let review = self.review else { return }
                let moment = ReviewMoment(appIsActive: UIApplication.shared.applicationState == .active,
                                          scene: self.window?.windowScene,
                                          homeIsIdle: self.home?.canBeRebuilt == true && self.home?.isAdOnScreen == false)
                if review.considerRequest(moment) != .userBusy { return }
            }
        }
    }

    /// Production always uses the persistent store. In-memory storage is chosen only explicitly:
    /// for the unit-test host and for UI tests launched with `--uitesting`.
    private static func makePersistence() -> AppPersistence {
        let environment = ProcessInfo.processInfo
        let isUnitTestHost = environment.environment["XCTestConfigurationFilePath"] != nil
        let isUITesting = environment.arguments.contains("--uitesting")
        return isUnitTestHost || isUITesting ? .inMemoryForTesting() : .production()
    }
}
