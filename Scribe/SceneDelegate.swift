import UIKit
import CloudKit
import os

class SceneDelegate: NSObject, UIWindowSceneDelegate {
    private let logger = Logger(subsystem: "com.gordonbeeming.scribe", category: "SceneDelegate")

    func windowScene(
        _ windowScene: UIWindowScene,
        userDidAcceptCloudKitShareWith cloudKitShareMetadata: CKShare.Metadata
    ) {
        logger.info("Received CloudKit share acceptance via scene delegate")
        Task {
            do {
                try await ShareManager.shared.acceptShare(cloudKitShareMetadata)
                logger.info("Share accepted successfully, fetching shared changes")
                SyncCoordinator.shared.fetchSharedChanges()
            } catch {
                logger.error("Failed to accept CloudKit share: \(error.localizedDescription)")
            }
        }
    }
}
