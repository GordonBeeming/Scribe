import Testing
import Foundation
@testable import Scribe

@Suite("Model Tests")
struct ModelTests {

    // MARK: - BudgetItem

    @Test("BudgetItem initializes with correct defaults")
    func budgetItemDefaults() {
        let item = BudgetItem(
            name: "Test",
            type: .expense,
            amount: 100,
            frequency: .monthly,
            dayOfMonth: 15,
            category: .other
        )

        #expect(item.name == "Test")
        #expect(item.type == .expense)
        #expect(item.amount == 100)
        #expect(item.currencyCode == "AUD")
        #expect(item.frequency == .monthly)
        #expect(item.dayOfMonth == 15)
        #expect(item.isActive == true)
        #expect(item.sortOrder == 0)
    }

    @Test("BudgetItem type maps to/from raw value")
    func budgetItemTypeMapping() {
        let item = BudgetItem(
            name: "Salary",
            type: .income,
            amount: 5000,
            frequency: .monthly,
            dayOfMonth: 14,
            category: .income
        )

        #expect(item.itemType == "income")
        #expect(item.type == .income)

        item.type = .expense
        #expect(item.itemType == "expense")
    }

    // MARK: - Occurrence

    @Test("Occurrence initializes with pending status")
    func occurrenceDefaults() {
        let occurrence = Occurrence(
            dueDate: Date(),
            expectedAmount: 100
        )

        #expect(occurrence.status == .pending)
        #expect(occurrence.confirmedAt == nil)
        #expect(occurrence.actualAmount == nil)
    }

    @Test("Occurrence status maps to/from raw value")
    func occurrenceStatusMapping() {
        let occurrence = Occurrence(
            dueDate: Date(),
            expectedAmount: 100,
            status: .confirmed,
            confirmedAt: Date()
        )

        #expect(occurrence.statusRaw == "confirmed")
        #expect(occurrence.status == .confirmed)
    }

    // MARK: - Enums

    @Test("Frequency has correct usesReferenceDate")
    func frequencyReferenceDate() {
        #expect(Frequency.monthly.usesReferenceDate == false)
        #expect(Frequency.weekly.usesReferenceDate == true)
        #expect(Frequency.fortnightly.usesReferenceDate == true)
        #expect(Frequency.yearly.usesReferenceDate == true)
        #expect(Frequency.quarterly.usesReferenceDate == true)
        #expect(Frequency.biYearly.usesReferenceDate == true)
    }

    @Test("ItemCategory has system images")
    func categorySystemImages() {
        for category in ItemCategory.allCases {
            #expect(!category.systemImage.isEmpty)
            #expect(!category.displayName.isEmpty)
        }
    }
}
