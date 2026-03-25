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
            await ShareManager.shared.handleShareAcceptance(cloudKitShareMetadata)
        }
    }
}
