import Foundation
import SwiftData
import os

/// How the app's data is stored for this run. In-memory is only ever chosen explicitly (tests / UI tests);
/// production never falls back to it, so temporary data can't masquerade as saved data.
enum PersistenceMode: Equatable {
    case persistent
    case inMemoryForTesting
}

/// Whether the app can safely read and write its data right now.
enum PersistenceState {
    case available(ModelContainer, PersistenceMode)
    /// Persistent storage could not be opened. Nothing was deleted; the user can retry.
    case unavailable(Error)

    var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }
}

/// Opens the SwiftData container. A failure produces `.unavailable` (shown to the user with a retry),
/// never a silent in-memory substitute, and never a destructive reset of the existing store.
final class AppPersistence {
    typealias ContainerFactory = () throws -> ModelContainer

    let mode: PersistenceMode
    /// Whether the last successful `open()` mirrors the store to iCloud.
    private(set) var isCloudActive = false
    /// Why sync couldn't start (shown in 設定), e.g. the pre-sync protection copy failed.
    private(set) var cloudProblem: String?
    private let factory: ContainerFactory
    private let cloudFactory: (() throws -> (ModelContainer, Bool, String?))?
    private let logger = Logger(subsystem: "FoodManager.HowCode", category: "Persistence")

    init(mode: PersistenceMode, factory: @escaping ContainerFactory) {
        self.mode = mode
        self.factory = factory
        cloudFactory = nil
    }

    /// `cloudFactory` returns the container, whether CloudKit is on, and a problem to show.
    /// (`cloudAware` only keeps this initializer apart from the trailing-closure one above.)
    init(mode: PersistenceMode, openingWithCloud cloudFactory: @escaping () throws -> (ModelContainer, Bool, String?), cloudAware: Bool) {
        self.mode = mode
        self.cloudFactory = cloudFactory
        factory = { try cloudFactory().0 }
    }

    /// The user's store, mirrored to their private iCloud database when sync is on and the one-time protection
    /// copy succeeded. Without iCloud (signed out, offline, disabled) the same store keeps working locally.
    static func production(settings: CloudSyncSettings = .shared, snapshots: ProtectionSnapshots = .shared) -> AppPersistence {
        AppPersistence(mode: .persistent, openingWithCloud: {
            guard settings.isEnabled else { return (try SwiftDataFridgeStore.makeContainer(), false, nil) }
            let outcome = CloudSyncPreparation.prepareIfNeeded(storeURL: SwiftDataFridgeStore.defaultStoreURL, settings: settings,
                                                                snapshots: snapshots, magnetImageDirectory: MagnetImageStore.defaultDirectory)
            switch outcome {
            case .ready:
                return (try SwiftDataFridgeStore.makeContainer(cloudKit: true), true, nil)
            case let .failed(message):
                return (try SwiftDataFridgeStore.makeContainer(), false, message)
            }
        }, cloudAware: true)
    }

    static func inMemoryForTesting() -> AppPersistence {
        AppPersistence(mode: .inMemoryForTesting) { try SwiftDataFridgeStore.makeContainer(inMemory: true) }
    }

    /// Attempts to open storage. Safe to call again for a retry.
    func open() -> PersistenceState {
        do {
            if let cloudFactory {
                let (container, cloud, problem) = try cloudFactory()
                isCloudActive = cloud
                cloudProblem = problem
                return .available(container, mode)
            }
            return .available(try factory(), mode)
        } catch {
            // Technical details are logged privately (not visible in shared logs), never shown in the UI.
            logger.error("Persistent store unavailable: \(String(describing: error), privacy: .private)")
            return .unavailable(error)
        }
    }
}

/// Everything the home screen needs once storage is confirmed available and the fridge has loaded.
struct AppSession {
    let fridgeStore: FridgeStore
    let foodStore: FoodStore
    /// The selected fridge.
    let loadResult: FridgeLoadResult
    let mode: PersistenceMode
    let directory: FridgeDirectory
    /// The one open container (a restore rebuilds the session from it; a second container is never opened).
    let container: ModelContainer
    let selection: FridgeSelectionStore
    let magnets: MagnetLibrary
    /// Shared refrigerators (nil unless `SharingPolicy` is active and iCloud sync runs).
    var sharing: SharingService? = nil

    /// Same storage, another fridge (re-reads stored fridges so door states and layouts are current).
    func selecting(_ fridgeID: UUID) throws -> AppSession {
        try directory.select(fridgeID)
        return AppSession(fridgeStore: fridgeStore, foodStore: foodStore, loadResult: directory.selected,
                          mode: mode, directory: directory, container: container, selection: selection, magnets: magnets,
                          sharing: sharing)
    }

    /// Backup service over this session's storage and preferences.
    func makeBackupService(defaults: UserDefaults = .standard) -> BackupService {
        BackupService(inventory: SwiftDataInventoryBackupStore(container: container),
                      preferences: UserDefaultsPreferencesBackupStore(defaults: defaults, selection: selection),
                      magnetImages: magnets.images,
                      recoveryDirectory: mode == .persistent ? BackupService.defaultRecoveryDirectory : nil)
    }
}

enum AppBootstrap {
    /// Opens storage and loads the fridge. Any failure is returned instead of being papered over.
    /// `sharing` is built for the opened container (nil while shared fridges are off).
    static func start(_ persistence: AppPersistence,
                      sharing: (ModelContainer) -> SharingService? = { _ in nil }) -> Result<AppSession, Error> {
        switch persistence.open() {
        case let .unavailable(error):
            return .failure(error)
        case let .available(container, mode):
            // Tests and UI tests keep their selection in memory, never in the user's preferences.
            let selection: FridgeSelectionStore = mode == .persistent ? UserDefaultsFridgeSelectionStore() : InMemoryFridgeSelectionStore()
            return makeSession(container: container, mode: mode, selection: selection, sharing: sharing(container))
        }
    }

    /// Fresh stores (fresh contexts, nothing cached) over an already open container. Used at launch and after a restore.
    /// With `sharing`, shared fridges join the personal ones through the routing stores.
    static func makeSession(container: ModelContainer, mode: PersistenceMode, selection: FridgeSelectionStore,
                            sharing: SharingService? = nil) -> Result<AppSession, Error> {
        // Settle anything iCloud delivered since the last launch (never assigns or deletes user data on its own).
        _ = try? SyncReconciler(container: container).run()
        let personalFridges = SwiftDataFridgeStore(container: container)
        let personalFood = SwiftDataFoodStore(container: container)
        let personalMagnets = SwiftDataMagnetStore(container: container)
        let fridgeStore: FridgeStore
        let foodStore: FoodStore
        let magnetStore: MagnetStore
        if let shared = sharing?.inventory {
            sharing?.finishPendingRemovals()
            fridgeStore = RoutingFridgeStore(personal: personalFridges, shared: shared)
            foodStore = RoutingFoodStore(personal: personalFood, shared: shared)
            magnetStore = RoutingMagnetStore(personal: personalMagnets, shared: shared)
        } else {
            fridgeStore = personalFridges
            foodStore = personalFood
            magnetStore = personalMagnets
        }
        do {
            let directory = try FridgeDirectory(fridgeStore: fridgeStore, foodStore: foodStore, selection: selection)
            let imageDirectory = MagnetImageStore.directory(for: container)
            let magnets = MagnetLibrary(store: magnetStore, images: MagnetImageStore(directory: imageDirectory))
            directory.onFridgeDeleted = { magnets.removeUnreferencedImages() }
            return .success(AppSession(fridgeStore: fridgeStore, foodStore: foodStore, loadResult: directory.selected,
                                       mode: mode, directory: directory, container: container, selection: selection,
                                       magnets: magnets, sharing: sharing))
        } catch {
            Logger(subsystem: "FoodManager.HowCode", category: "Persistence")
                .error("Fridge load failed: \(String(describing: error), privacy: .private)")
            return .failure(error)
        }
    }
}
