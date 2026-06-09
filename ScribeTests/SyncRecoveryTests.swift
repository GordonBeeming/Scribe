import Testing
import Foundation
import SwiftData
@testable import Scribe

@Suite("Sync Recovery Tests")
struct SyncRecoveryTests {

    /// The "Unstuck" action must null every cached change tag and drop both
    /// persisted sync-state tokens, so the engines re-fetch and re-upload from a
    /// clean slate. CKSyncEngine itself is skipped in the test environment, so this
    /// exercises the local data-clearing contract of forceFullResync().
    @Test("forceFullResync clears cached records and persisted sync state")
    @MainActor
    func forceFullResyncClearsState() throws {
        // Match the app: SwiftData's automatic CloudKit is disabled (sync is via
        // CKSyncEngine), otherwise the schema fails CloudKit's optional-attribute check.
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(
            for: BudgetItem.self, AmountOverride.self, Occurrence.self,
            FamilyMember.self, DashboardSection.self, UserPreferences.self,
            configurations: config
        )
        let context = container.mainContext

        let item = BudgetItem(
            name: "Rent", type: .expense, amount: 100,
            frequency: .monthly, dayOfMonth: 1, category: .housing
        )
        item.ckRecordData = Data([1, 2, 3])
        context.insert(item)
        try context.save()

        let defaults = UserDefaults(suiteName: SharedModelContainer.appGroupIdentifier)
        defaults?.set(Data([9, 9]), forKey: "syncEngineState")
        defaults?.set(Data([8, 8]), forKey: "sharedSyncEngineState")

        SyncCoordinator.shared.start(with: container)
        SyncCoordinator.shared.forceFullResync()

        #expect(item.ckRecordData == nil)
        #expect(defaults?.object(forKey: "syncEngineState") == nil)
        #expect(defaults?.object(forKey: "sharedSyncEngineState") == nil)
    }
}
