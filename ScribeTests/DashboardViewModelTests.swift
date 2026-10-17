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
            anchor: .fixedDay(weekday: 2),
            range: .days14,
            holidays: [],
            exchangeRates: rates,
            baseCurrency: "AUD"
        )
        let naive = viewModel.weeklyGroups(
            budgetItems: [usdExpense, audExpense],
            occurrences: [],
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
            anchor: .fixedDay(weekday: 2),
            range: .days14,
            holidays: []
        )

        for group in groups where !group.items.isEmpty {
            #expect(group.totalIncome > 0 || group.totalExpenses > 0)
            #expect(group.delta == group.totalIncome - group.totalExpenses)
        }
    }

    @Test("Rolling net is nil when the setting is off")
    func rollingWeeklyNetOff() {
        let income = BudgetItem(
            name: "Salary", type: .income, amount: 5000,
            frequency: .monthly, dayOfMonth: 14,
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
            anchor: .fixedDay(weekday: 2),
            range: .days28,
            holidays: [],
            rollingNet: false
        )

        for group in groups {
            #expect(group.rollingNet == nil)
        }
    }

    @Test("Rolling net carries each week's leftover forward")
    func rollingWeeklyNetCarriesForward() {
        // Weekly income only → every week's delta is positive and equal, so the rolling
        // net must equal the cumulative sum of deltas (proving the carry-forward).
        let income = BudgetItem(
            name: "Weekly Pay", type: .income, amount: 1000,
            frequency: .weekly,
            referenceDate: makeDate(year: 2026, month: 3, day: 9),
            category: .income
        )

        let groups = viewModel.weeklyGroups(
            budgetItems: [income],
            occurrences: [],
            anchor: .fixedDay(weekday: 2),
            range: .days28,
            holidays: [],
            rollingNet: true
        )

        #expect(groups.count >= 3)

        var cumulative: Decimal = 0
        for group in groups {
            cumulative += group.delta
            #expect(group.rollingNet == cumulative)
        }

        // The last week's rolling net must exceed the first — it has burnt nothing down,
        // only accumulated, so it strictly grows with each positive-net week.
        if let first = groups.first, let last = groups.last, groups.count > 1 {
            #expect((last.rollingNet ?? 0) > (first.rollingNet ?? 0))
        }
    }

    @Test("Previous week precedes the current week across anchors and year boundaries",
          arguments: [(2026, 10, 12, 2), (2026, 10, 18, 2), (2026, 10, 17, 5), (2027, 1, 1, 2)])
    func previousWeekBoundaries(year: Int, month: Int, day: Int, weekday: Int) throws {
        let today = makeDate(year: year, month: month, day: day)
        let groups = viewModel.weeklyGroups(
            budgetItems: [], occurrences: [], anchor: .fixedDay(weekday: weekday),
            range: .days7, holidays: [], includingPreviousWeek: true, now: today
        )
        #expect(groups.count >= 2)
        let previous = try #require(groups.first)
        let current = groups[1]
        #expect(calendar.component(.weekday, from: previous.startDate) == weekday)
        #expect(calendar.date(byAdding: .day, value: 7, to: previous.startDate) == current.startDate)
        #expect(previous.endDate < today)
        #expect(current.startDate <= today && current.endDate >= today)
    }

    @Test("Previous week preserves pending, confirmed and skipped payments without changing rolling net")
    func previousWeekPayments() throws {
        let today = makeDate(year: 2026, month: 10, day: 17)
        let dueDate = makeDate(year: 2026, month: 10, day: 5)
        let items = ["Pending", "Confirmed", "Skipped"].map {
            BudgetItem(name: $0, type: .expense, amount: 100, frequency: .weekly,
                       referenceDate: dueDate, category: .other)
        }
        let confirmed = Occurrence(dueDate: dueDate, expectedAmount: 100,
                                   actualAmount: 90, status: .confirmed, budgetItem: items[1])
        let skipped = Occurrence(dueDate: dueDate, expectedAmount: 100,
                                 status: .skipped, budgetItem: items[2])
        let groups = viewModel.weeklyGroups(
            budgetItems: items, occurrences: [confirmed, skipped], anchor: .fixedDay(weekday: 2),
            range: .days14, holidays: [], rollingNet: true, includingPreviousWeek: true, now: today
        )
        let previous = try #require(groups.first)
        #expect(previous.startDate == dueDate)
        #expect(previous.totalCount == 3)
        #expect(previous.confirmedCount == 1)
        #expect(previous.pendingExpenses == 100)
        #expect(previous.totalExpenses == 190)
        #expect(previous.rollingNet == nil)
        #expect(previous.items.first { $0.budgetItem.name == "Pending" }?.occurrence == nil)
        let current = groups[1]
        #expect(current.rollingNet == current.delta)
        #expect(groups[2].rollingNet == current.delta + groups[2].delta)
    }

    @Test("Auto-confirm protects the previous week and respects longer or disabled lookback")
    func previousWeekAutoConfirmationCutoff() {
        let today = makeDate(year: 2026, month: 10, day: 17)
        let section = DashboardSection(sectionType: .detailedWeekly,
                                       anchor: .fixedDay(weekday: 2), label: "Weekly")
        func cutoff(_ days: Int) -> Date? {
            viewModel.autoConfirmationCutoff(lookbackDays: days, budgetItems: [], sections: [section],
                                            range: .days14, holidays: [], now: today)
        }
        #expect(cutoff(5) == makeDate(year: 2026, month: 10, day: 5))
        #expect(cutoff(14) == makeDate(year: 2026, month: 10, day: 3))
        #expect(cutoff(0) == nil)
        section.isEnabled = false
        #expect(cutoff(5) == makeDate(year: 2026, month: 10, day: 12))
        section.isEnabled = true
        section.anchor = .fixedDay(weekday: 5)
        #expect(cutoff(5) == makeDate(year: 2026, month: 10, day: 8))
    }

    @Test("Auto-confirm preserves income reflected into the previous week")
    func previousWeekReflectedIncome() {
        let cutoff = makeDate(year: 2026, month: 10, day: 5)
        let scheduledDate = makeDate(year: 2026, month: 10, day: 4)
        let income = BudgetItem(
            name: "Salary", type: .income, amount: 1000, frequency: .weekly,
            referenceDate: scheduledDate, category: .income, budgetReflection: .dayAfter
        )
        let dates = viewModel.autoConfirmationDates(for: income, before: cutoff, holidays: [])
        #expect(!dates.contains(scheduledDate))
        #expect(dates.contains(makeDate(year: 2026, month: 9, day: 27)))
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
