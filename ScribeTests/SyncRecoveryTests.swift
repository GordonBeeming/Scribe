import Testing
import Foundation
import SwiftData
@testable import Scribe

@Suite("Sync Recovery Tests")
struct SyncRecoveryTests {

    /// The "Unstuck" action must drop both persisted sync-state tokens (so the
    /// engines re-fetch from scratch) while **preserving** each record's cached
    /// ckRecordData — that data carries the zone identity needed to route shared
    /// records back to the shared zone, so clearing it would duplicate shared data
    /// into the private zone. CKSyncEngine is skipped in the test environment, so
    /// this exercises the local state contract of forceFullResync().
    @Test("forceFullResync drops sync-state tokens and preserves cached records")
    @MainActor
    func forceFullResyncDropsTokens() throws {
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
        let cachedRecord = Data([1, 2, 3])
        item.ckRecordData = cachedRecord
        context.insert(item)
        try context.save()

        let defaults = UserDefaults(suiteName: SharedModelContainer.appGroupIdentifier)
        defaults?.set(Data([9, 9]), forKey: "syncEngineState")
        defaults?.set(Data([8, 8]), forKey: "sharedSyncEngineState")

        SyncCoordinator.shared.start(with: container)
        SyncCoordinator.shared.forceFullResync()

        // Tokens dropped so the engines re-fetch from scratch...
        #expect(defaults?.object(forKey: "syncEngineState") == nil)
        #expect(defaults?.object(forKey: "sharedSyncEngineState") == nil)
        // ...but the cached record (and its zone identity) is preserved.
        #expect(item.ckRecordData == cachedRecord)
    }
}
