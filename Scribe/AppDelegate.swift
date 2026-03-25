import UIKit
import CloudKit
import os

class AppDelegate: NSObject, UIApplicationDelegate {
    private let logger = Logger(subsystem: "com.gordonbeeming.scribe", category: "AppDelegate")

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Only register for remote notifications if not in a test environment
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            application.registerForRemoteNotifications()
        }
        return true
    }

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        config.delegateClass = SceneDelegate.self
        return config
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any]
    ) async -> UIBackgroundFetchResult {
        .newData
    }

    // Fallback for non-scene-based delivery (kept for compatibility)
    func application(
        _ application: UIApplication,
        userDidAcceptCloudKitShareWith cloudKitShareMetadata: CKShare.Metadata
    ) {
        logger.info("Received CloudKit share acceptance via app delegate (fallback)")
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
