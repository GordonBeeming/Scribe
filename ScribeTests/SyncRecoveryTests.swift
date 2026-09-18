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
    /// cached zone. The synchronous half of the reclaim deletes the other account's custom sections
    /// and reports which well-known records need their private-zone copy fetched. It deliberately
    /// does *not* clear those caches: the in-memory values may be the other member's, so the repair
    /// has to come from the server, which needs CloudKit and so is out of reach here.
    @Test("reclaimPerUserRecords deletes foreign custom sections and reports the records to recover")
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
        let toRecover = SyncCoordinator.shared.reclaimPerUserRecords()

        // Both well-known records are reported for a private-zone lookup, in our own zone.
        let recoverNames = Set(toRecover.map(\.recordName))
        #expect(recoverNames == [
            UserPreferences.sharedID.uuidString,
            DashboardSection.defaultSummaryID.uuidString
        ])
        #expect(toRecover.allSatisfy { $0.zoneID.ownerName == CKCurrentUserDefaultName })

        // The foreign custom section is gone; the well-known one is kept for the lookup to repair.
        let remainingIDs = try context.fetch(FetchDescriptor<DashboardSection>()).map(\.id)
        #expect(remainingIDs.contains(DashboardSection.defaultSummaryID))
        #expect(!remainingIDs.contains(foreignSectionID))
    }

    /// A legacy shared deletion the server couldn't classify stays quarantined across launches, so
    /// the identity that survives the round-trip has to be the whole record ID. Losing the zone or
    /// the owner would send the retry at the wrong record.
    @Test("The legacy deletion quarantine round-trips a full record ID through UserDefaults")
    @MainActor
    func quarantineRoundTripsRecordIDs() {
        let coordinator = SyncCoordinator.shared
        let first = CKRecord.ID(
            recordName: "11111111-1111-1111-1111-111111111111",
            zoneID: CKRecordZone.ID(zoneName: "ScribeBudgetZone", ownerName: "_someoneelse")
        )
        let second = CKRecord.ID(
            recordName: "22222222-2222-2222-2222-222222222222",
            zoneID: CKRecordZone.ID(zoneName: "OtherZone", ownerName: "_anotherowner")
        )

        coordinator.saveLegacySharedDeletionQuarantine([first, second])
        let loaded = coordinator.loadLegacySharedDeletionQuarantine()

        #expect(loaded.count == 2)
        #expect(loaded.first == first)
        #expect(loaded.last == second)
        #expect(loaded.first?.zoneID.ownerName == "_someoneelse")
        #expect(loaded.last?.zoneID.zoneName == "OtherZone")

        // Emptying clears the key, which is what lets the scrub finally set its done flag.
        coordinator.saveLegacySharedDeletionQuarantine([])
        #expect(coordinator.loadLegacySharedDeletionQuarantine().isEmpty)
    }

    /// A push made before the engines exist only lives in the buffer, so the buffer has to survive
    /// termination: a lost deletion is never retried, because nothing walks a deleted model again.
    /// Which engine and which kind both have to come back, or the change lands in the wrong
    /// database or as the wrong operation.
    @Test("The deferred change buffer round-trips target and kind through UserDefaults")
    @MainActor
    func deferredChangesRoundTripThroughUserDefaults() {
        let coordinator = SyncCoordinator.shared
        let saveID = CKRecord.ID(
            recordName: "33333333-3333-3333-3333-333333333333",
            zoneID: CKRecordZone.ID(zoneName: "ScribeBudgetZone", ownerName: CKCurrentUserDefaultName)
        )
        let deleteID = CKRecord.ID(
            recordName: "44444444-4444-4444-4444-444444444444",
            zoneID: CKRecordZone.ID(zoneName: "ScribeBudgetZone", ownerName: "_someoneelse")
        )

        coordinator.saveDeferredChanges([
            SyncCoordinator.DeferredChange(target: .privateDatabase, change: .saveRecord(saveID)),
            SyncCoordinator.DeferredChange(target: .sharedDatabase, change: .deleteRecord(deleteID))
        ])
        let loaded = coordinator.loadDeferredChanges()

        #expect(loaded.count == 2)
        #expect(loaded.first?.target == .privateDatabase)
        #expect(loaded.last?.target == .sharedDatabase)

        if case .saveRecord(let id) = loaded.first?.change {
            #expect(id == saveID)
            #expect(id.zoneID.ownerName == CKCurrentUserDefaultName)
        } else {
            Issue.record("First entry should have come back as a save")
        }

        if case .deleteRecord(let id) = loaded.last?.change {
            #expect(id == deleteID)
            #expect(id.zoneID.ownerName == "_someoneelse")
        } else {
            Issue.record("Second entry should have come back as a deletion")
        }

        coordinator.saveDeferredChanges([])
        #expect(coordinator.loadDeferredChanges().isEmpty)
        #expect(UserDefaults(suiteName: SharedModelContainer.appGroupIdentifier)?
            .object(forKey: "deferredRecordZoneChanges") == nil)
    }

    /// A relaunch under a different iCloud account never sees a `.switchAccounts` event, because the
    /// engine only reports a switch it observed. The remembered user record name is what lets the
    /// next launch notice and throw away the previous account's buffered work.
    @Test("The last known iCloud user record name round-trips through UserDefaults")
    @MainActor
    func lastKnownUserRecordNameRoundTrips() {
        let coordinator = SyncCoordinator.shared
        let defaults = UserDefaults(suiteName: SharedModelContainer.appGroupIdentifier)
        defaults?.removeObject(forKey: "lastKnownUserRecordName")

        // Nothing remembered on a first run, so there is no previous account to compare against.
        #expect(coordinator.loadLastKnownUserRecordName() == nil)

        coordinator.saveLastKnownUserRecordName("_accountA")
        #expect(coordinator.loadLastKnownUserRecordName() == "_accountA")

        coordinator.saveLastKnownUserRecordName("_accountB")
        #expect(coordinator.loadLastKnownUserRecordName() == "_accountB")

        defaults?.removeObject(forKey: "lastKnownUserRecordName")
    }
}
