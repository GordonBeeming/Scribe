import Foundation
import CloudKit
import SwiftUI
import os

/// Manages CKShare lifecycle: creation, acceptance, participant management.
final class ShareManager: @unchecked Sendable {
    static let shared = ShareManager()

    private let logger = Logger(subsystem: "com.gordonbeeming.scribe", category: "ShareManager")
    private let shareRecordNameKey = "ScribeShareRecordName"

    private var defaults: UserDefaults? {
        UserDefaults(suiteName: SharedModelContainer.appGroupIdentifier)
    }

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
        defaults?.set(share.recordID.recordName, forKey: shareRecordNameKey)
        logger.info("Created share with recordName: \(share.recordID.recordName)")
        await MainActor.run { currentShare = share }
        return share
    }

    func fetchExistingShare() async throws {
        let zoneID = CloudKitManager.shared.zoneID
        let database = CloudKitManager.shared.privateDatabase

        guard let recordName = defaults?.string(forKey: shareRecordNameKey) else {
            logger.info("No persisted share record name found")
            return
        }

        let recordID = CKRecord.ID(recordName: recordName, zoneID: zoneID)
        let record = try await database.record(for: recordID)
        if let share = record as? CKShare {
            logger.info("Fetched existing share: \(recordName)")
            await MainActor.run { currentShare = share }
        }
    }

    func acceptShare(_ metadata: CKShare.Metadata) async throws {
        try await CloudKitManager.shared.container.accept(metadata)
    }
}

// MARK: - UICloudSharingController Presentation

#if os(iOS)
extension ShareManager {
    /// Retains the delegate for the lifetime of the presented controller.
    @MainActor
    private static var activeSharingDelegate: SharingDelegate?

    @MainActor
    func presentSharing() {
        guard let windowScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }),
              let rootVC = windowScene.windows.first(where: \.isKeyWindow)?.rootViewController
        else { return }

        var presenter = rootVC
        while let presented = presenter.presentedViewController {
            presenter = presented
        }

        let container = CloudKitManager.shared.container
        let delegate = SharingDelegate()
        Self.activeSharingDelegate = delegate

        let controller: UICloudSharingController
        if let share = currentShare {
            controller = UICloudSharingController(share: share, container: container)
        } else {
            controller = UICloudSharingController { _, completion in
                Task {
                    do {
                        let share = try await ShareManager.shared.createShare()
                        completion(share, container, nil)
                    } catch {
                        completion(nil, nil, error)
                    }
                }
            }
        }
        controller.delegate = delegate
        presenter.present(controller, animated: true)
    }
}

private final class SharingDelegate: NSObject, UICloudSharingControllerDelegate {
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
#endif
