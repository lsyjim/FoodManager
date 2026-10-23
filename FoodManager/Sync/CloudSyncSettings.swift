import CloudKit
import CryptoKit
import Foundation

enum CloudSyncConstants {
    /// The app's CloudKit container. Data lives in each user's *private* database only.
    static let containerIdentifier = "iCloud.FoodManager.HowCode"
}

enum CloudAccountState: Equatable {
    case available
    case noAccount
    case restricted
    case temporarilyUnavailable
    case unknown

    var isAvailable: Bool { self == .available }
}

/// The iCloud account, behind a protocol so tests never touch CloudKit.
protocol CloudAccountProvider {
    func accountState() async -> CloudAccountState
    /// A stable, hashed identifier of the signed-in iCloud user for this app's container (nil if unknown).
    func accountFingerprint() async -> String?
}

struct CloudKitAccountProvider: CloudAccountProvider {
    private var container: CKContainer { CKContainer(identifier: CloudSyncConstants.containerIdentifier) }

    func accountState() async -> CloudAccountState {
        guard let status = try? await container.accountStatus() else { return .unknown }
        switch status {
        case .available: return .available
        case .noAccount: return .noAccount
        case .restricted: return .restricted
        case .temporarilyUnavailable: return .temporarilyUnavailable
        default: return .unknown
        }
    }

    func accountFingerprint() async -> String? {
        guard let recordID = try? await container.userRecordID() else { return nil }
        return Self.hash(recordID.recordName)
    }

    static func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}
