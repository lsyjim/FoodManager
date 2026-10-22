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
    private let factory: ContainerFactory
    private let logger = Logger(subsystem: "FoodManager.HowCode", category: "Persistence")

    init(mode: PersistenceMode, factory: @escaping ContainerFactory) {
        self.mode = mode
        self.factory = factory
    }

    static func production() -> AppPersistence {
        AppPersistence(mode: .persistent) { try SwiftDataFridgeStore.makeContainer(inMemory: false) }
    }

    static func inMemoryForTesting() -> AppPersistence {
        AppPersistence(mode: .inMemoryForTesting) { try SwiftDataFridgeStore.makeContainer(inMemory: true) }
    }

    /// Attempts to open storage. Safe to call again for a retry.
    func open() -> PersistenceState {
        do {
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

    /// Same storage, another fridge (re-reads stored fridges so door states and layouts are current).
    func selecting(_ fridgeID: UUID) throws -> AppSession {
        try directory.select(fridgeID)
        return AppSession(fridgeStore: fridgeStore, foodStore: foodStore, loadResult: directory.selected,
                          mode: mode, directory: directory, container: container, selection: selection)
    }

    /// Backup service over this session's storage and preferences.
    func makeBackupService(defaults: UserDefaults = .standard) -> BackupService {
        BackupService(inventory: SwiftDataInventoryBackupStore(container: container),
                      preferences: UserDefaultsPreferencesBackupStore(defaults: defaults, selection: selection),
                      recoveryDirectory: mode == .persistent ? BackupService.defaultRecoveryDirectory : nil)
    }
}

enum AppBootstrap {
    /// Opens storage and loads the fridge. Any failure is returned instead of being papered over.
    static func start(_ persistence: AppPersistence) -> Result<AppSession, Error> {
        switch persistence.open() {
        case let .unavailable(error):
            return .failure(error)
        case let .available(container, mode):
            // Tests and UI tests keep their selection in memory, never in the user's preferences.
            let selection: FridgeSelectionStore = mode == .persistent ? UserDefaultsFridgeSelectionStore() : InMemoryFridgeSelectionStore()
            return makeSession(container: container, mode: mode, selection: selection)
        }
    }

    /// Fresh stores (fresh contexts, nothing cached) over an already open container. Used at launch and after a restore.
    static func makeSession(container: ModelContainer, mode: PersistenceMode, selection: FridgeSelectionStore) -> Result<AppSession, Error> {
        let fridgeStore = SwiftDataFridgeStore(container: container)
        let foodStore = SwiftDataFoodStore(container: container)
        do {
            let directory = try FridgeDirectory(fridgeStore: fridgeStore, foodStore: foodStore, selection: selection)
            return .success(AppSession(fridgeStore: fridgeStore, foodStore: foodStore, loadResult: directory.selected,
                                       mode: mode, directory: directory, container: container, selection: selection))
        } catch {
            Logger(subsystem: "FoodManager.HowCode", category: "Persistence")
                .error("Fridge load failed: \(String(describing: error), privacy: .private)")
            return .failure(error)
        }
    }
}
