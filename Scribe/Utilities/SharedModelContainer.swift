import Foundation
import SwiftData
import os

enum SharedModelContainer {
    static let appGroupIdentifier = "group.com.gordonbeeming.scribe"

    private static let logger = Logger(subsystem: "com.gordonbeeming.scribe", category: "SharedModelContainer")

    static let schema = Schema([
        BudgetItem.self,
        AmountOverride.self,
        Occurrence.self,
        FamilyMember.self,
        DashboardSection.self,
        QuickAdjustment.self,
        UserPreferences.self,
    ])

    static var sharedStoreURL: URL {
        // Prefer App Group container (shared with widget), fall back to app support
        if let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) {
            let url = containerURL.appendingPathComponent("Scribe.store")
            logger.info("Using App Group store: \(url.path)")
            return url
        }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        let url = appSupport.appendingPathComponent("Scribe.store")
        logger.warning("App Group unavailable, falling back to: \(url.path)")
        return url
    }

    @MainActor
    static var shared: ModelContainer = {
        // Try with the shared URL first, fall back to default config
        do {
            let config = ModelConfiguration(
                "Scribe",
                schema: schema,
                url: sharedStoreURL,
                cloudKitDatabase: .none
            )
            let container = try ModelContainer(for: schema, configurations: [config])
            logger.info("ModelContainer created at shared URL")
            return container
        } catch {
            logger.error("ModelContainer failed at shared URL: \(error.localizedDescription) — falling back to default")
            // Fallback: default location (useful for tests / missing entitlements)
            do {
                return try ModelContainer(for: schema)
            } catch {
                fatalError("Failed to create ModelContainer: \(error)")
            }
        }
    }()
}
