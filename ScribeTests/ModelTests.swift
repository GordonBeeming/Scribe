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

    // MARK: - BudgetItem Income Fields

    @Test("BudgetItem budgetReflection defaults to paymentDate")
    func budgetItemReflectionDefault() {
        let item = BudgetItem(
            name: "Test", type: .income, amount: 100,
            frequency: .monthly, dayOfMonth: 14,
            category: .income
        )
        #expect(item.budgetReflection == .paymentDate)
        #expect(item.budgetReflectionRaw == nil)
    }

    @Test("BudgetItem budgetReflection round-trips through raw value")
    func budgetItemReflectionRoundTrip() {
        let item = BudgetItem(
            name: "Test", type: .income, amount: 100,
            frequency: .monthly, dayOfMonth: 14,
            category: .income,
            budgetReflection: .dayAfter
        )
        #expect(item.budgetReflection == .dayAfter)
        #expect(item.budgetReflectionRaw == "dayAfter")
    }

    @Test("BudgetItem payDayAdjustmentWeekdays parses comma-separated string")
    func budgetItemAdjustmentWeekdays() {
        let item = BudgetItem(
            name: "Test", type: .income, amount: 100,
            frequency: .monthly, dayOfMonth: 14,
            category: .income,
            payDayAdjustmentDays: "1,7"
        )
        #expect(item.payDayAdjustmentWeekdays == [1, 7])
    }

    @Test("BudgetItem payDayAdjustmentWeekdays set writes sorted string")
    func budgetItemAdjustmentWeekdaysSet() {
        let item = BudgetItem(
            name: "Test", type: .income, amount: 100,
            frequency: .monthly, dayOfMonth: 14,
            category: .income
        )
        item.payDayAdjustmentWeekdays = [7, 1]
        #expect(item.payDayAdjustmentDays == "1,7")
    }

    @Test("BudgetItem empty adjustment weekdays returns nil")
    func budgetItemEmptyAdjustmentWeekdays() {
        let item = BudgetItem(
            name: "Test", type: .income, amount: 100,
            frequency: .monthly, dayOfMonth: 14,
            category: .income
        )
        item.payDayAdjustmentWeekdays = []
        #expect(item.payDayAdjustmentDays == nil)
    }

    // MARK: - DashboardSection

    @Test("DashboardSection anchor encodes and decodes fixedDay")
    func dashboardSectionFixedDayAnchor() {
        let section = DashboardSection(
            sectionType: .detailedWeekly,
            anchor: .fixedDay(weekday: 5),
            label: "Test"
        )
        let decoded = section.anchor
        if case .fixedDay(let weekday) = decoded {
            #expect(weekday == 5)
        } else {
            Issue.record("Expected fixedDay anchor")
        }
    }

    @Test("DashboardSection anchor encodes and decodes linkedIncome")
    func dashboardSectionLinkedIncomeAnchor() {
        let testID = UUID()
        let section = DashboardSection(
            sectionType: .monthlySummary,
            anchor: .linkedIncome(budgetItemID: testID),
            label: "Monthly"
        )
        let decoded = section.anchor
        if case .linkedIncome(let id) = decoded {
            #expect(id == testID)
        } else {
            Issue.record("Expected linkedIncome anchor")
        }
    }

    @Test("DashboardSection anchor encodes and decodes fixedDayOfMonth")
    func dashboardSectionFixedDayOfMonthAnchor() {
        let section = DashboardSection(
            sectionType: .monthlySummary,
            anchor: .fixedDayOfMonth(day: 15),
            label: "Mid-month"
        )
        let decoded = section.anchor
        if case .fixedDayOfMonth(let day) = decoded {
            #expect(day == 15)
        } else {
            Issue.record("Expected fixedDayOfMonth anchor")
        }
    }
}
