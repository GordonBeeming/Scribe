import Testing
import Foundation
import CloudKit
@testable import Scribe

@Suite("Record Merge Tests")
struct RecordMergeTests {

    private static let zoneID = CKRecordZone.ID(zoneName: "ScribeBudgetZone", ownerName: CKCurrentUserDefaultName)

    private static let older = Date(timeIntervalSince1970: 1_000)
    private static let newer = Date(timeIntervalSince1970: 2_000)

    /// A BudgetItem-shaped record with the same record ID on every side, so the merge sees one
    /// record three devices disagree about.
    private static func makeRecord(name: String?, notes: String?, modifiedAt: Date) -> CKRecord {
        let recordID = CKRecord.ID(recordName: "5D3D3D3D-0000-0000-0000-00000000000A", zoneID: zoneID)
        let record = CKRecord(recordType: RecordConversion.budgetItemRecordType, recordID: recordID)
        record["name"] = name as CKRecordValue?
        record["notes"] = notes as CKRecordValue?
        record["modifiedAt"] = modifiedAt as CKRecordValue
        return record
    }

    @Test("Only the client changed a key — the client value wins and needs a re-push")
    func onlyClientChanged() {
        let ancestor = Self.makeRecord(name: "Rent", notes: "old", modifiedAt: Self.older)
        let client = Self.makeRecord(name: "Mortgage", notes: "old", modifiedAt: Self.newer)
        let server = Self.makeRecord(name: "Rent", notes: "old", modifiedAt: Self.older)

        let outcome = RecordMerge.threeWay(ancestor: ancestor, client: client, server: server)

        #expect(outcome.record["name"] as? String == "Mortgage")
        #expect(outcome.differsFromServer)
        #expect(outcome.record["modifiedAt"] as? Date == Self.newer)
    }

    /// The caller caches the server record it passed in as the ancestor for the next merge, so it
    /// has to still describe what the server actually holds. A merge that wrote into it would
    /// claim the server already had our edits and the next conflict would discard them.
    @Test("Merging leaves the server record the caller passed in untouched")
    func serverRecordIsNotMutated() {
        let ancestor = Self.makeRecord(name: "Rent", notes: "old", modifiedAt: Self.older)
        let client = Self.makeRecord(name: "Mortgage", notes: "old", modifiedAt: Self.newer)
        let server = Self.makeRecord(name: "Rent", notes: "old", modifiedAt: Self.older)

        let outcome = RecordMerge.threeWay(ancestor: ancestor, client: client, server: server)

        #expect(outcome.differsFromServer)
        #expect(outcome.record !== server)
        #expect(server["name"] as? String == "Rent")
        #expect(server["modifiedAt"] as? Date == Self.older)
    }

    /// The conflict path merges a second time against the record we submitted, not against the
    /// cache. A user who reverts a field back to its cached value while the save is in flight has
    /// still diverged from what we sent, and diffing against the cache would read that revert as
    /// "unchanged" and let the in-flight value win.
    @Test("A revert made while the save was in flight survives the conflict merge")
    func revertDuringInFlightSaveSurvives() {
        let submitted = Self.makeRecord(name: "B", notes: nil, modifiedAt: Self.older)
        let localAfterRevert = Self.makeRecord(name: "A", notes: nil, modifiedAt: Self.newer)
        let conflictMerged = Self.makeRecord(name: "B", notes: nil, modifiedAt: Self.older)

        let outcome = RecordMerge.threeWay(
            ancestor: submitted,
            client: localAfterRevert,
            server: conflictMerged
        )

        #expect(outcome.record["name"] as? String == "A")
        #expect(outcome.differsFromServer)
    }

    @Test("Only the server changed a key — the server value stands and no re-push is needed")
    func onlyServerChanged() {
        let ancestor = Self.makeRecord(name: "Rent", notes: "old", modifiedAt: Self.older)
        let client = Self.makeRecord(name: "Rent", notes: "old", modifiedAt: Self.older)
        let server = Self.makeRecord(name: "Mortgage", notes: "old", modifiedAt: Self.newer)

        let outcome = RecordMerge.threeWay(ancestor: ancestor, client: client, server: server)

        #expect(outcome.record["name"] as? String == "Mortgage")
        #expect(!outcome.differsFromServer)
    }

    @Test("Each side changed a different key — both edits survive")
    func differentKeysBothSurvive() {
        let ancestor = Self.makeRecord(name: "Rent", notes: "old", modifiedAt: Self.older)
        let client = Self.makeRecord(name: "Mortgage", notes: "old", modifiedAt: Self.newer)
        let server = Self.makeRecord(name: "Rent", notes: "reviewed", modifiedAt: Self.newer)

        let outcome = RecordMerge.threeWay(ancestor: ancestor, client: client, server: server)

        #expect(outcome.record["name"] as? String == "Mortgage")
        #expect(outcome.record["notes"] as? String == "reviewed")
        #expect(outcome.differsFromServer)
    }

    @Test("Same key changed to different values — the newer edit wins")
    func sameKeyNewerWins() {
        let ancestor = Self.makeRecord(name: "Rent", notes: nil, modifiedAt: Self.older)
        let client = Self.makeRecord(name: "Mortgage", notes: nil, modifiedAt: Self.newer)
        let server = Self.makeRecord(name: "Home loan", notes: nil, modifiedAt: Self.older)

        let outcome = RecordMerge.threeWay(ancestor: ancestor, client: client, server: server)

        #expect(outcome.record["name"] as? String == "Mortgage")
        #expect(outcome.differsFromServer)
    }

    @Test("Same key changed to different values at the same instant — the server wins the tie")
    func sameKeyTieGoesToServer() {
        let ancestor = Self.makeRecord(name: "Rent", notes: nil, modifiedAt: Self.older)
        let client = Self.makeRecord(name: "Mortgage", notes: nil, modifiedAt: Self.newer)
        let server = Self.makeRecord(name: "Home loan", notes: nil, modifiedAt: Self.newer)

        let outcome = RecordMerge.threeWay(ancestor: ancestor, client: client, server: server)

        #expect(outcome.record["name"] as? String == "Home loan")
        #expect(!outcome.differsFromServer)
    }

    @Test("Both sides made the same edit — nothing to re-push")
    func sameKeySameValue() {
        let ancestor = Self.makeRecord(name: "Rent", notes: nil, modifiedAt: Self.older)
        let client = Self.makeRecord(name: "Mortgage", notes: nil, modifiedAt: Self.newer)
        let server = Self.makeRecord(name: "Mortgage", notes: nil, modifiedAt: Self.newer)

        let outcome = RecordMerge.threeWay(ancestor: ancestor, client: client, server: server)

        #expect(outcome.record["name"] as? String == "Mortgage")
        #expect(!outcome.differsFromServer)
    }

    @Test("A key cleared on the client and untouched on the server is removed")
    func clearedKeyIsRemoved() {
        let ancestor = Self.makeRecord(name: "Rent", notes: "old", modifiedAt: Self.older)
        let client = Self.makeRecord(name: "Rent", notes: nil, modifiedAt: Self.newer)
        let server = Self.makeRecord(name: "Rent", notes: "old", modifiedAt: Self.older)

        let outcome = RecordMerge.threeWay(ancestor: ancestor, client: client, server: server)

        #expect(outcome.record["notes"] == nil)
        #expect(outcome.differsFromServer)
    }

    @Test("No ancestor and a newer client — the whole client copy is taken")
    func noAncestorClientNewer() {
        let client = Self.makeRecord(name: "Mortgage", notes: "mine", modifiedAt: Self.newer)
        let server = Self.makeRecord(name: "Rent", notes: "theirs", modifiedAt: Self.older)

        let outcome = RecordMerge.threeWay(ancestor: nil, client: client, server: server)

        #expect(outcome.record["name"] as? String == "Mortgage")
        #expect(outcome.record["notes"] as? String == "mine")
        #expect(outcome.differsFromServer)
    }

    @Test("No ancestor and a newer server — the server copy is kept")
    func noAncestorServerNewer() {
        let client = Self.makeRecord(name: "Mortgage", notes: "mine", modifiedAt: Self.older)
        let server = Self.makeRecord(name: "Rent", notes: "theirs", modifiedAt: Self.newer)

        let outcome = RecordMerge.threeWay(ancestor: nil, client: client, server: server)

        #expect(outcome.record["name"] as? String == "Rent")
        #expect(outcome.record["notes"] as? String == "theirs")
        #expect(!outcome.differsFromServer)
    }

    /// Caches written before records were archived whole decode to system fields only, so there is
    /// nothing to diff against and the merge has to fall back to whole-record last-writer-wins.
    @Test("A system-fields-only ancestor behaves like no ancestor at all")
    func legacyAncestorFallsBackToLastWriterWins() {
        let legacyAncestor = CKRecord(
            recordType: RecordConversion.budgetItemRecordType,
            recordID: CKRecord.ID(recordName: "5D3D3D3D-0000-0000-0000-00000000000A", zoneID: Self.zoneID)
        )
        let client = Self.makeRecord(name: "Mortgage", notes: "mine", modifiedAt: Self.newer)
        let server = Self.makeRecord(name: "Rent", notes: "theirs", modifiedAt: Self.older)

        #expect(legacyAncestor.allKeys().isEmpty)

        let outcome = RecordMerge.threeWay(ancestor: legacyAncestor, client: client, server: server)

        #expect(outcome.record["name"] as? String == "Mortgage")
        #expect(outcome.record["notes"] as? String == "mine")
        #expect(outcome.differsFromServer)
    }

    /// Without field values in the cached record there is no ancestor to merge against, so the
    /// round-trip is what makes the three-way merge possible at all.
    @Test("Encoding a record and decoding it back keeps the custom fields")
    func encodeRecordRoundTripsFields() throws {
        let record = CKRecord(
            recordType: RecordConversion.budgetItemRecordType,
            recordID: CKRecord.ID(recordName: "5D3D3D3D-0000-0000-0000-00000000000B", zoneID: Self.zoneID)
        )
        record["name"] = "Rent" as CKRecordValue
        record["amount"] = NSDecimalNumber(decimal: Decimal(1234.56)) as CKRecordValue

        let data = RecordConversion.encodeRecord(record)
        let decoded = try #require(RecordConversion.decodeLastKnownRecord(from: data))

        #expect(decoded["name"] as? String == "Rent")
        #expect((decoded["amount"] as? NSNumber)?.decimalValue == Decimal(1234.56))
        #expect(decoded.recordID.recordName == record.recordID.recordName)
    }
}
