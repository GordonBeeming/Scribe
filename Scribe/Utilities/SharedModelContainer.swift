import Foundation
import SwiftData

enum SharedModelContainer {
    static let appGroupIdentifier = "group.com.gordonbeeming.scribe"

    static let schema = Schema([
        BudgetItem.self,
        AmountOverride.self,
        Occurrence.self,
        FamilyMember.self,
        DashboardSection.self,
        QuickAdjustment.self,
    ])

    static var sharedStoreURL: URL {
        // Prefer App Group container (shared with widget), fall back to app support
        if let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) {
            return containerURL.appendingPathComponent("Scribe.store")
        }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        return appSupport.appendingPathComponent("Scribe.store")
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
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            // Fallback: default location (useful for tests / missing entitlements)
            do {
                return try ModelContainer(for: schema)
            } catch {
                fatalError("Failed to create ModelContainer: \(error)")
            }
        }
    }()
}
