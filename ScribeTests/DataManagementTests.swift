import Testing
import Foundation
import SwiftData
@testable import Scribe

@Suite("Data Management Tests")
struct DataManagementTests {

    /// Returns the container, not its `mainContext`: a context doesn't keep its container
    /// alive, and using one after the container has gone traps inside SwiftData. Match the
    /// app and disable SwiftData's automatic CloudKit (sync is via CKSyncEngine), otherwise
    /// the schema fails CloudKit's optional-attribute check.
    @MainActor
    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return try ModelContainer(
            for: BudgetItem.self, AmountOverride.self, Occurrence.self,
            FamilyMember.self, DashboardSection.self, UserPreferences.self,
            configurations: config
        )
    }

    /// A file in the shape the importer accepts. `modifiedAt` is what decides a merge,
    /// so every test that cares about it passes its own.
    private func exportJSON(itemID: UUID, name: String, amount: String,
                            modifiedAt: String, isActive: Bool = true) -> Data {
        """
        {
          "exportDate": "2026-09-19T00:00:00Z",
          "appVersion": "1.3",
          "familyMembers": [],
          "budgetItems": [{
            "id": "\(itemID.uuidString)",
            "name": "\(name)",
            "itemType": "expense",
            "amount": \(amount),
            "currencyCode": "AUD",
            "frequencyRaw": "monthly",
            "dayOfMonth": 15,
            "categoryRaw": "housing",
            "isActive": \(isActive),
            "sortOrder": 0,
            "showLast": false,
            "createdAt": "2026-01-01T00:00:00Z",
            "modifiedAt": "\(modifiedAt)",
            "familyMemberIDs": []
          }],
          "amountOverrides": [],
          "occurrences": []
        }
        """.data(using: .utf8)!
    }

    @Test("A new item is added and counted")
    @MainActor
    func addsNewItem() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let id = UUID()

        let summary = try DataManagementService.importData(
            exportJSON(itemID: id, name: "Rent", amount: "3820", modifiedAt: "2026-09-19T00:00:00Z"),
            into: context, mode: .merge)

        #expect(summary == ImportSummary(added: 1))
        let items = try context.fetch(FetchDescriptor<BudgetItem>())
        #expect(items.count == 1)
        #expect(items.first?.amount == 3820)
    }

    @Test("A newer file updates the existing item in place")
    @MainActor
    func updatesWhenNewer() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let id = UUID()
        _ = try DataManagementService.importData(
            exportJSON(itemID: id, name: "Rent", amount: "3820", modifiedAt: "2026-09-19T00:00:00Z"),
            into: context, mode: .merge)

        let summary = try DataManagementService.importData(
            exportJSON(itemID: id, name: "Rent (13 Chapel St)", amount: "3900",
                       modifiedAt: "2026-09-20T00:00:00Z"),
            into: context, mode: .merge)

        #expect(summary == ImportSummary(updated: 1))
        let items = try context.fetch(FetchDescriptor<BudgetItem>())
        #expect(items.count == 1, "the same id must update, not duplicate")
        #expect(items.first?.name == "Rent (13 Chapel St)")
        #expect(items.first?.amount == 3900)
    }

    /// The reason the summary exists: this import reports success and changes nothing.
    @Test("An older file leaves the item alone and says so")
    @MainActor
    func skipsWhenNotNewer() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let id = UUID()
        _ = try DataManagementService.importData(
            exportJSON(itemID: id, name: "Rent", amount: "3820", modifiedAt: "2026-09-19T00:00:00Z"),
            into: context, mode: .merge)

        let summary = try DataManagementService.importData(
            exportJSON(itemID: id, name: "Stale", amount: "1", modifiedAt: "2026-01-02T00:00:00Z"),
            into: context, mode: .merge)

        #expect(summary == ImportSummary(skipped: 1))
        let items = try context.fetch(FetchDescriptor<BudgetItem>())
        #expect(items.first?.amount == 3820, "the older file must not win")
    }

    @Test("An item arriving closed is counted as closed")
    @MainActor
    func countsClosedItems() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let summary = try DataManagementService.importData(
            exportJSON(itemID: UUID(), name: "Zwift", amount: "299.99",
                       modifiedAt: "2026-09-19T00:00:00Z", isActive: false),
            into: context, mode: .merge)

        #expect(summary == ImportSummary(added: 1, closed: 1))
    }

    @Test("Merge never deletes what the file leaves out")
    @MainActor
    func mergeKeepsAbsentItems() throws {
        let container = try makeContainer()
        let context = container.mainContext
        _ = try DataManagementService.importData(
            exportJSON(itemID: UUID(), name: "Keep me", amount: "10", modifiedAt: "2026-09-19T00:00:00Z"),
            into: context, mode: .merge)

        _ = try DataManagementService.importData(
            exportJSON(itemID: UUID(), name: "New", amount: "20", modifiedAt: "2026-09-19T00:00:00Z"),
            into: context, mode: .merge)

        #expect(try context.fetchCount(FetchDescriptor<BudgetItem>()) == 2)
    }

    @Test("Replace clears what was there first")
    @MainActor
    func replaceClearsFirst() throws {
        let container = try makeContainer()
        let context = container.mainContext
        _ = try DataManagementService.importData(
            exportJSON(itemID: UUID(), name: "Old", amount: "10", modifiedAt: "2026-09-19T00:00:00Z"),
            into: context, mode: .merge)

        let summary = try DataManagementService.importData(
            exportJSON(itemID: UUID(), name: "New", amount: "20", modifiedAt: "2026-09-19T00:00:00Z"),
            into: context, mode: .replace)

        #expect(summary == ImportSummary(added: 1))
        let items = try context.fetch(FetchDescriptor<BudgetItem>())
        #expect(items.count == 1)
        #expect(items.first?.name == "New")
    }

    @Test("Export round-trips back through import")
    @MainActor
    func exportRoundTrips() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let item = BudgetItem(name: "Optus", type: .expense, amount: 256.43,
                              frequency: .monthly, dayOfMonth: 21, category: .utilities)
        context.insert(item)
        try context.save()

        let data = try DataManagementService.exportData(from: context)
        let freshContainer = try makeContainer()
        let fresh = freshContainer.mainContext
        let summary = try DataManagementService.importData(data, into: fresh, mode: .merge)

        #expect(summary.added == 1)
        let items = try fresh.fetch(FetchDescriptor<BudgetItem>())
        #expect(items.first?.id == item.id)
        #expect(items.first?.amount == 256.43)
        #expect(items.first?.dayOfMonth == 21)
    }

    @Test("A date-only string is rejected, and nothing is half-applied")
    @MainActor
    func rejectsDateOnlyStrings() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let bad = exportJSON(itemID: UUID(), name: "Rent", amount: "10", modifiedAt: "2026-09-19")

        #expect(throws: (any Error).self) {
            try DataManagementService.importData(bad, into: context, mode: .merge)
        }
        #expect(try context.fetchCount(FetchDescriptor<BudgetItem>()) == 0)
    }

    /// Foundation's `.iso8601` strategy accepts fractional seconds, so a file carrying them
    /// imports fine. Pinned because it's the opposite of what the format name suggests.
    @Test("Fractional seconds are accepted")
    @MainActor
    func acceptsFractionalSeconds() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let summary = try DataManagementService.importData(
            exportJSON(itemID: UUID(), name: "Rent", amount: "10",
                       modifiedAt: "2026-09-19T00:00:00.000Z"),
            into: context, mode: .merge)

        #expect(summary.added == 1)
    }

    // MARK: - The message the alert shows

    @Test("The summary message names what landed")
    @MainActor
    func summaryMessageReadsWell() {
        let message = DataManagementSection.message(
            for: ImportSummary(added: 20, updated: 22, closed: 49, overrides: 51))
        #expect(message.contains("42 items: 20 added, 22 updated."))
        #expect(message.contains("49 of them closed."))
        #expect(message.contains("51 amount overrides"))
    }

    @Test("A no-op import says nothing changed")
    @MainActor
    func summaryMessageForNoOp() {
        let message = DataManagementSection.message(for: ImportSummary(skipped: 3))
        #expect(message.contains("No items changed."))
        #expect(message.contains("3 items were left alone"))
    }
}
