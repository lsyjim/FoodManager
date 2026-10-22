import Foundation

/// Structured deep links used by widgets (and any future entry point):
///
///     foodmanager://home
///     foodmanager://add[?compartment=<uuid>][&fridge=<uuid>]
///     foodmanager://reminders[?storage=all|refrigerated|frozen][&kind=all|expiringSoon|expired|storage]
///     foodmanager://food?id=<uuid>
///
/// Parsing is strict: an unknown destination or a malformed parameter makes the whole link invalid
/// (the app then shows the fridge home with a message). Whether a referenced food or compartment still
/// exists is checked later by the app, never assumed.
struct AppDeepLink: Equatable {
    enum Destination: Equatable {
        case home
        case quickAdd(compartmentID: UUID?)
        case reminders(storage: StorageFilter, kind: ReminderKindFilter)
        case food(UUID)
    }

    static let scheme = "foodmanager"

    var destination: Destination
    var refrigeratorID: UUID?

    init(_ destination: Destination, refrigeratorID: UUID? = nil) {
        self.destination = destination
        self.refrigeratorID = refrigeratorID
    }

    var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        var items: [URLQueryItem] = []
        switch destination {
        case .home:
            components.host = "home"
        case let .quickAdd(compartmentID):
            components.host = "add"
            if let compartmentID { items.append(URLQueryItem(name: "compartment", value: compartmentID.uuidString)) }
        case let .reminders(storage, kind):
            components.host = "reminders"
            items.append(URLQueryItem(name: "storage", value: storage.linkValue))
            items.append(URLQueryItem(name: "kind", value: kind.linkValue))
        case let .food(id):
            components.host = "food"
            items.append(URLQueryItem(name: "id", value: id.uuidString))
        }
        if let refrigeratorID { items.append(URLQueryItem(name: "fridge", value: refrigeratorID.uuidString)) }
        components.queryItems = items.isEmpty ? nil : items
        return components.url!
    }

    init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] {
            guard query[item.name] == nil, let value = item.value else { return nil } // no duplicates / empty values
            query[item.name] = value
        }
        func uuid(_ key: String) -> UUID?? {
            guard let raw = query[key] else { return .some(nil) }
            return UUID(uuidString: raw).map { .some($0) } ?? nil
        }
        guard case let .some(fridge) = uuid("fridge") else { return nil }
        refrigeratorID = fridge

        switch components.host?.lowercased() {
        case "home":
            destination = .home
        case "add":
            guard case let .some(compartment) = uuid("compartment") else { return nil }
            destination = .quickAdd(compartmentID: compartment)
        case "reminders":
            guard let storage = query["storage"].map(StorageFilter.init(linkValue:)) ?? .all,
                  let kind = query["kind"].map(ReminderKindFilter.init(linkValue:)) ?? .all else { return nil }
            destination = .reminders(storage: storage, kind: kind)
        case "food":
            guard case let .some(id?) = uuid("id") else { return nil }
            destination = .food(id)
        default:
            return nil
        }
    }
}

extension StorageFilter {
    var linkValue: String {
        switch self {
        case .all: return "all"
        case .refrigerated: return "refrigerated"
        case .frozen: return "frozen"
        }
    }

    init?(linkValue: String) {
        guard let match = Self.allCases.first(where: { $0.linkValue == linkValue }) else { return nil }
        self = match
    }
}

extension ReminderKindFilter {
    var linkValue: String {
        switch self {
        case .all: return "all"
        case .expiringSoon: return "expiringSoon"
        case .expired: return "expired"
        case .storedTooLong: return "storage"
        }
    }

    init?(linkValue: String) {
        guard let match = Self.allCases.first(where: { $0.linkValue == linkValue }) else { return nil }
        self = match
    }
}
