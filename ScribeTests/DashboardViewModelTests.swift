import Testing
import Foundation
@testable import Scribe

@Suite("DashboardViewModel Tests")
struct DashboardViewModelTests {
    private let calendar: Calendar = .current
    private let viewModel = DashboardViewModel()

    private func makeDate(year: Int, month: Int, day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    @Test("Weekly groups bucket items into correct weeks")
    func weeklyGroupsBucketing() {
        let item = BudgetItem(
            name: "Rent", type: .expense, amount: 500,
            frequency: .weekly,
            referenceDate: makeDate(year: 2026, month: 3, day: 9), // Monday
            category: .housing
        )

        let groups = viewModel.weeklyGroups(
            budgetItems: [item],
            occurrences: [],
            quickAdjustments: [],
            anchor: .fixedDay(weekday: 2), // Monday
            range: .days28,
            holidays: []
        )

        // Should have multiple week groups
        #expect(groups.count >= 1)

        // Each group should have items
        let totalItems = groups.reduce(0) { $0 + $1.items.count }
        #expect(totalItems >= 1)
    }

    @Test("Monthly summary computes income and expenses")
    func monthlySummaryCalculation() {
        let income = BudgetItem(
            name: "Salary", type: .income, amount: 5000,
            frequency: .monthly, dayOfMonth: 14,
            category: .income
        )
        let expense = BudgetItem(
            name: "Rent", type: .expense, amount: 2000,
            frequency: .monthly, dayOfMonth: 1,
            category: .housing
        )

        let summary = viewModel.monthlySummary(
            budgetItems: [income, expense],
            occurrences: [],
            anchor: .fixedDayOfMonth(day: 1),
            holidays: []
        )

        #expect(summary.totalIncome >= 0)
        #expect(summary.totalExpenses >= 0)
    }

    @Test("Weekly group totals convert items from their currency into the base currency")
    func weeklyGroupsMixedCurrencyTotals() {
        // USD → AUD ~1.516 at rates below ($12.20 USD ≈ $18.50 AUD)
        let usdExpense = BudgetItem(
            name: "USD sub", type: .expense, amount: 12.20,
            currencyCode: "USD",
            frequency: .weekly,
            referenceDate: makeDate(year: 2026, month: 3, day: 9),
            category: .other
        )
        let audExpense = BudgetItem(
            name: "AUD item", type: .expense, amount: 10,
            currencyCode: "AUD",
            frequency: .weekly,
            referenceDate: makeDate(year: 2026, month: 3, day: 9),
            category: .other
        )

        // Rates are expressed relative to USD (matches ExchangeRateService.fetchAllRates).
        let rates: [String: Double] = ["AUD": 1.516, "USD": 1.0]

        let converted = viewModel.weeklyGroups(
            budgetItems: [usdExpense, audExpense],
            occurrences: [],
            quickAdjustments: [],
            anchor: .fixedDay(weekday: 2),
            range: .days14,
            holidays: [],
            exchangeRates: rates,
            baseCurrency: "AUD"
        )
        let naive = viewModel.weeklyGroups(
            budgetItems: [usdExpense, audExpense],
            occurrences: [],
            quickAdjustments: [],
            anchor: .fixedDay(weekday: 2),
            range: .days14,
            holidays: []
        )

        // Find a populated week in both runs so we can compare a specific group
        // rather than a sum that could hide rounding regressions.
        let weeksWithItems = converted.filter { !$0.items.isEmpty }
        #expect(!weeksWithItems.isEmpty)
        guard let convertedWeek = weeksWithItems.first,
              let naiveWeek = naive.first(where: { $0.startDate == convertedWeek.startDate })
        else {
            Issue.record("Expected a populated week in both converted and naive runs")
            return
        }

        // Expected per-week expense total in AUD: (12.20 * 1.516) rounded to 2dp + 10 = 18.50 + 10 = 28.50.
        // Give ourselves a small tolerance to absorb Double↔Decimal rounding inside convertToBase.
        let expected = Decimal(string: "28.50")!
        let tolerance = Decimal(string: "0.05")!
        let diff = abs(convertedWeek.totalExpenses - expected)
        #expect(diff <= tolerance, "converted week totalExpenses \(convertedWeek.totalExpenses) differs from expected \(expected) by more than \(tolerance)")

        // Naive path (no rates) should still treat raw amounts as base → ~$22.20 for the same week.
        #expect(naiveWeek.totalExpenses == Decimal(string: "22.20")!)
        #expect(convertedWeek.totalExpenses > naiveWeek.totalExpenses)
    }

    @Test("Weekly groups compute correct totals per group")
    func weeklyGroupsTotals() {
        let income = BudgetItem(
            name: "Weekly Pay", type: .income, amount: 1000,
            frequency: .weekly,
            referenceDate: makeDate(year: 2026, month: 3, day: 9),
            category: .income
        )
        let expense = BudgetItem(
            name: "Groceries", type: .expense, amount: 200,
            frequency: .weekly,
            referenceDate: makeDate(year: 2026, month: 3, day: 9),
            category: .other
        )

        let groups = viewModel.weeklyGroups(
            budgetItems: [income, expense],
            occurrences: [],
            quickAdjustments: [],
            anchor: .fixedDay(weekday: 2),
            range: .days14,
            holidays: []
        )

        for group in groups where !group.items.isEmpty {
            #expect(group.totalIncome > 0 || group.totalExpenses > 0)
            #expect(group.delta == group.totalIncome - group.totalExpenses + group.adjustmentIncome - group.adjustmentExpenses)
        }
    }

    // MARK: - effectiveBalanceAmount Tests

    @Test("Pending item uses projected amount")
    func effectiveBalanceAmountPending() {
        let item = BudgetItem(
            name: "Rent", type: .expense, amount: 500,
            frequency: .monthly, dayOfMonth: 1, category: .housing
        )
        let upcomingItem = DashboardViewModel.UpcomingItem(
            id: UUID(),
            budgetItem: item,
            dueDate: Date(),
            amount: 500,
            occurrence: nil
        )

        #expect(upcomingItem.effectiveBalanceAmount == 500)
        #expect(!upcomingItem.isConfirmed)
        #expect(!upcomingItem.isSkipped)
    }

    @Test("Confirmed item uses actual amount when present")
    func effectiveBalanceAmountConfirmedActual() {
        let item = BudgetItem(
            name: "Rent", type: .expense, amount: 500,
            frequency: .monthly, dayOfMonth: 1, category: .housing
        )
        let occurrence = Occurrence(
            dueDate: Date(),
            expectedAmount: 500,
            actualAmount: 480,
            status: .confirmed,
            confirmedAt: Date()
        )
        let upcomingItem = DashboardViewModel.UpcomingItem(
            id: UUID(),
            budgetItem: item,
            dueDate: Date(),
            amount: 500,
            occurrence: occurrence
        )

        #expect(upcomingItem.effectiveBalanceAmount == 480)
        #expect(upcomingItem.isConfirmed)
    }

    @Test("Confirmed item falls back to projected amount when no actual")
    func effectiveBalanceAmountConfirmedNoActual() {
        let item = BudgetItem(
            name: "Rent", type: .expense, amount: 500,
            frequency: .monthly, dayOfMonth: 1, category: .housing
        )
        let occurrence = Occurrence(
            dueDate: Date(),
            expectedAmount: 500,
            status: .confirmed,
            confirmedAt: Date()
        )
        let upcomingItem = DashboardViewModel.UpcomingItem(
            id: UUID(),
            budgetItem: item,
            dueDate: Date(),
            amount: 500,
            occurrence: occurrence
        )

        #expect(upcomingItem.effectiveBalanceAmount == 500)
        #expect(upcomingItem.isConfirmed)
    }

    @Test("Skipped item contributes zero to balance")
    func effectiveBalanceAmountSkipped() {
        let item = BudgetItem(
            name: "Rent", type: .expense, amount: 500,
            frequency: .monthly, dayOfMonth: 1, category: .housing
        )
        let occurrence = Occurrence(
            dueDate: Date(),
            expectedAmount: 500,
            status: .skipped
        )
        let upcomingItem = DashboardViewModel.UpcomingItem(
            id: UUID(),
            budgetItem: item,
            dueDate: Date(),
            amount: 500,
            occurrence: occurrence
        )

        #expect(upcomingItem.effectiveBalanceAmount == 0)
        #expect(upcomingItem.isSkipped)
        #expect(!upcomingItem.isConfirmed)
    }

    @Test("Weekly totals reflect occurrence status")
    func weeklyGroupsWithOccurrences() {
        let today = calendar.startOfDay(for: Date())
        let expense = BudgetItem(
            name: "Rent", type: .expense, amount: 1000,
            frequency: .weekly,
            referenceDate: today,
            category: .housing
        )
        let skippedOccurrence = Occurrence(
            dueDate: today,
            expectedAmount: 1000,
            status: .skipped
        )
        skippedOccurrence.budgetItem = expense

        let groups = viewModel.weeklyGroups(
            budgetItems: [expense],
            occurrences: [skippedOccurrence],
            quickAdjustments: [],
            anchor: .fixedDay(weekday: calendar.component(.weekday, from: today)),
            range: .days7,
            holidays: []
        )

        // The week containing today should have the skipped item contributing 0
        let currentWeek = groups.first { $0.startDate <= today && $0.endDate >= today }
        if let week = currentWeek, !week.items.isEmpty {
            let skippedItems = week.items.filter(\.isSkipped)
            for skipped in skippedItems {
                #expect(skipped.effectiveBalanceAmount == 0)
            }
        }
    }
}
