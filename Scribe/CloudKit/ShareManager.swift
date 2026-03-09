import Foundation
import CloudKit
import SwiftUI

/// Manages CKShare lifecycle: creation, acceptance, participant management.
final class ShareManager: @unchecked Sendable {
    static let shared = ShareManager()

    private init() {}

    @MainActor
    var currentShare: CKShare?

    @MainActor
    var participants: [CKShare.Participant] {
        currentShare?.participants ?? []
    }

    func createShare() async throws -> CKShare {
        let zoneID = CloudKitManager.shared.zoneID
        let share = CKShare(recordZoneID: zoneID)
        share[CKShare.SystemFieldKey.title] = "Scribe Family Budget" as CKRecordValue
        share.publicPermission = .none

        let database = CloudKitManager.shared.privateDatabase
        let _ = try await database.modifyRecords(saving: [share], deleting: [])
        await MainActor.run { currentShare = share }
        return share
    }

    func fetchExistingShare() async throws {
        let zoneID = CloudKitManager.shared.zoneID
        let database = CloudKitManager.shared.privateDatabase

        // Fetch all shares in the zone
        let query = CKQuery(recordType: "cloudkit.share", predicate: NSPredicate(value: true))
        let results = try await database.records(matching: query, inZoneWith: zoneID)
        for (_, result) in results.matchResults {
            if let record = try? result.get(), let share = record as? CKShare {
                await MainActor.run { currentShare = share }
                return
            }
        }
    }

    func acceptShare(_ metadata: CKShare.Metadata) async throws {
        try await CloudKitManager.shared.container.accept(metadata)
    }
}

// MARK: - UICloudSharingController Wrapper

#if os(iOS)
struct CloudSharingView: UIViewControllerRepresentable {
    let share: CKShare?
    let container: CKContainer

    func makeUIViewController(context: Context) -> UICloudSharingController {
        if let share {
            let controller = UICloudSharingController(share: share, container: container)
            controller.delegate = context.coordinator
            return controller
        } else {
            let controller = UICloudSharingController { [container] controller, completion in
                Task {
                    do {
                        let share = try await ShareManager.shared.createShare()
                        completion(share, container, nil)
                    } catch {
                        completion(nil, nil, error)
                    }
                }
            }
            controller.delegate = context.coordinator
            return controller
        }
    }

    func updateUIViewController(_ uiViewController: UICloudSharingController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator: NSObject, UICloudSharingControllerDelegate {
        func cloudSharingController(
            _ csc: UICloudSharingController,
            failedToSaveShareWithError error: Error
        ) {
            // Handle error
        }

        func itemTitle(for csc: UICloudSharingController) -> String? {
            "Scribe Family Budget"
        }
    }
}
#endif
