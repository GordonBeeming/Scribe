import Foundation
import CloudKit

/// Manages CKSyncEngine lifecycle, zone creation, and push/pull operations.
final class CloudKitManager: @unchecked Sendable {
    static let shared = CloudKitManager()

    let containerIdentifier = "iCloud.com.gordonbeeming.scribe"
    let zoneName = "ScribeBudgetZone"

    private(set) lazy var container: CKContainer = {
        CKContainer(identifier: containerIdentifier)
    }()

    var zoneID: CKRecordZone.ID {
        CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)
    }

    private init() {}

    var privateDatabase: CKDatabase {
        container.privateCloudDatabase
    }

    var sharedDatabase: CKDatabase {
        container.sharedCloudDatabase
    }

    func checkAccountStatus() async throws -> CKAccountStatus {
        try await container.accountStatus()
    }

    func createZoneIfNeeded() async throws {
        let zone = CKRecordZone(zoneID: zoneID)
        let operation = CKModifyRecordZonesOperation(recordZonesToSave: [zone])
        operation.qualityOfService = .userInitiated
        try await privateDatabase.modifyRecordZones(saving: [zone], deleting: [])
    }

    func createSubscriptionIfNeeded() async throws {
        let subscriptionID = "scribe-budget-changes"
        // Check if subscription already exists
        do {
            _ = try await privateDatabase.subscription(for: subscriptionID)
            return // Already exists
        } catch {
            // Subscription doesn't exist, create it
        }

        let subscription = CKDatabaseSubscription(subscriptionID: subscriptionID)
        let notificationInfo = CKSubscription.NotificationInfo()
        notificationInfo.shouldSendContentAvailable = true
        subscription.notificationInfo = notificationInfo
        try await privateDatabase.save(subscription)
    }
}
