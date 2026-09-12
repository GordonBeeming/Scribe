import Testing
import Foundation
import CloudKit
import SwiftData
@testable import Scribe

// Serialized because every test drives the SyncCoordinator singleton, which holds one
// model container at a time.
@Suite("Sync Recovery Tests", .serialized)
struct SyncRecoveryTests {

    private static func makeContainer() throws -> ModelContainer {
        // Match the app: SwiftData's automatic CloudKit is disabled (sync is via
        // CKSyncEngine), otherwise the schema fails CloudKit's optional-attribute check.
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return try ModelContainer(
            for: BudgetItem.self, AmountOverride.self, Occurrence.self,
            FamilyMember.self, DashboardSection.self, UserPreferences.self,
            configurations: config
        )
    }

    /// A cached record that claims the other family member's zone — what the per-user
    /// settings hijack leaves behind on the participant's device.
    private static func foreignZoneCache(recordType: String, id: UUID) -> Data {
        let zoneID = CKRecordZone.ID(zoneName: "ScribeBudgetZone", ownerName: "_someoneelse")
        let record = CKRecord(
            recordType: recordType,
            recordID: CKRecord.ID(recordName: id.uuidString, zoneID: zoneID)
        )
        return RecordConversion.encodeRecord(record)
    }

    /// The "Unstuck" action must drop both persisted sync-state tokens (so the
    /// engines re-fetch from scratch) while **preserving** each record's cached
    /// ckRecordData — that data carries the zone identity needed to route shared
    /// records back to the shared zone, so clearing it would duplicate shared data
    /// into the private zone. CKSyncEngine is skipped in the test environment, so
    /// this exercises the local state contract of forceFullResync().
    @Test("forceFullResync drops sync-state tokens and preserves cached records")
    @MainActor
    func forceFullResyncDropsTokens() throws {
        let container = try Self.makeContainer()
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

    /// Both accounts push UserPreferences and the two default DashboardSections under the same
    /// fixed UUIDs, so the owner's copies arrived through the share and rewrote the participant's
    /// cached zone. Reclaiming resets the shared-identity records to this account's own and drops
    /// the other account's custom sections, which only exist locally because they leaked in.
    @Test("reclaimPerUserRecords clears hijacked caches and deletes foreign custom sections")
    @MainActor
    func reclaimPerUserRecordsRepairsHijackedSettings() throws {
        let container = try Self.makeContainer()
        let context = container.mainContext

        let preferences = UserPreferences()
        preferences.ckRecordData = Self.foreignZoneCache(
            recordType: RecordConversion.userPreferencesRecordType,
            id: preferences.id
        )
        context.insert(preferences)

        let defaultSection = DashboardSection(
            id: DashboardSection.defaultSummaryID,
            sectionType: .monthlySummary,
            anchor: .fixedDayOfMonth(day: 1),
            label: "Monthly"
        )
        defaultSection.ckRecordData = Self.foreignZoneCache(
            recordType: RecordConversion.dashboardSectionRecordType,
            id: defaultSection.id
        )
        context.insert(defaultSection)

        let foreignSectionID = UUID()
        let foreignSection = DashboardSection(
            id: foreignSectionID,
            sectionType: .detailedWeekly,
            anchor: .fixedDay(weekday: 2),
            label: "Their custom section"
        )
        foreignSection.ckRecordData = Self.foreignZoneCache(
            recordType: RecordConversion.dashboardSectionRecordType,
            id: foreignSectionID
        )
        context.insert(foreignSection)

        try context.save()

        // start() returns before touching CloudKit under test, so the reclaim runs directly.
        SyncCoordinator.shared.start(with: container)
        SyncCoordinator.shared.reclaimPerUserRecords()

        #expect(preferences.ckRecordData == nil)
        #expect(defaultSection.ckRecordData == nil)

        let remainingIDs = try context.fetch(FetchDescriptor<DashboardSection>()).map(\.id)
        #expect(remainingIDs.contains(DashboardSection.defaultSummaryID))
        #expect(!remainingIDs.contains(foreignSectionID))
    }
}
