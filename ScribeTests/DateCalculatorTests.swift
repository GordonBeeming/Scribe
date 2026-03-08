import Testing
import Foundation
@testable import Scribe

@Suite("DateCalculator Tests")
struct DateCalculatorTests {
    private let calendar: Calendar = .current

    private func makeDate(year: Int, month: Int, day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    // MARK: - Monthly

    @Test("Monthly item on day 15 generates correct dates")
    func monthlyDay15() {
        let item = BudgetItem(
            name: "Rent",
            type: .expense,
            amount: 750,
            frequency: .monthly,
            dayOfMonth: 15,
            category: .housing
        )

        let start = makeDate(year: 2026, month: 1, day: 1)
        let end = makeDate(year: 2026, month: 3, day: 31)

        let dates = DateCalculator.occurrenceDates(for: item, in: start...end)

        #expect(dates.count == 3)
        #expect(calendar.component(.day, from: dates[0]) == 15)
        #expect(calendar.component(.month, from: dates[0]) == 1)
        #expect(calendar.component(.day, from: dates[1]) == 15)
        #expect(calendar.component(.month, from: dates[1]) == 2)
        #expect(calendar.component(.day, from: dates[2]) == 15)
        #expect(calendar.component(.month, from: dates[2]) == 3)
    }

    @Test("Monthly item on day 31 clamps to short months")
    func monthlyDay31ClampsFeb() {
        let item = BudgetItem(
            name: "End of Month",
            type: .expense,
            amount: 100,
            frequency: .monthly,
            dayOfMonth: 31,
            category: .other
        )

        let start = makeDate(year: 2026, month: 2, day: 1)
        let end = makeDate(year: 2026, month: 2, day: 28)

        let dates = DateCalculator.occurrenceDates(for: item, in: start...end)

        #expect(dates.count == 1)
        #expect(calendar.component(.day, from: dates[0]) == 28)
    }

    // MARK: - Weekly

    @Test("Weekly item generates every 7 days from reference")
    func weeklyFromReference() {
        let refDate = makeDate(year: 2026, month: 1, day: 5) // Monday

        let item = BudgetItem(
            name: "Tiani Salary",
            type: .income,
            amount: 800,
            frequency: .weekly,
            referenceDate: refDate,
            category: .income
        )

        let start = makeDate(year: 2026, month: 1, day: 5)
        let end = makeDate(year: 2026, month: 1, day: 26)

        let dates = DateCalculator.occurrenceDates(for: item, in: start...end)

        // Should have Jan 5, 12, 19, 26 = 4 dates
        #expect(dates.count == 4)

        // Verify 7-day spacing between consecutive dates
        for i in 1..<dates.count {
            let diff = Calendar.current.dateComponents([.day], from: dates[i-1], to: dates[i]).day!
            #expect(diff == 7)
        }
    }

    // MARK: - Fortnightly

    @Test("Fortnightly item generates every 14 days")
    func fortnightlyDates() {
        let refDate = makeDate(year: 2026, month: 1, day: 1)

        let item = BudgetItem(
            name: "Fortnightly Bill",
            type: .expense,
            amount: 200,
            frequency: .fortnightly,
            referenceDate: refDate,
            category: .other
        )

        let start = makeDate(year: 2026, month: 1, day: 1)
        let end = makeDate(year: 2026, month: 2, day: 28)

        let dates = DateCalculator.occurrenceDates(for: item, in: start...end)

        // Jan 1, 15, 29; Feb 12, 26 = 5 dates
        #expect(dates.count >= 4)

        // Verify 14-day spacing
        for i in 1..<dates.count {
            let diff = calendar.dateComponents([.day], from: dates[i-1], to: dates[i]).day!
            #expect(diff == 14)
        }
    }

    // MARK: - Yearly

    @Test("Yearly item generates on same date each year")
    func yearlyDates() {
        let refDate = makeDate(year: 2025, month: 6, day: 15)

        let item = BudgetItem(
            name: "Annual Insurance",
            type: .expense,
            amount: 2000,
            frequency: .yearly,
            referenceDate: refDate,
            category: .insurance
        )

        let start = makeDate(year: 2025, month: 1, day: 1)
        let end = makeDate(year: 2027, month: 12, day: 31)

        let dates = DateCalculator.occurrenceDates(for: item, in: start...end)

        #expect(dates.count == 3)
        for date in dates {
            #expect(calendar.component(.month, from: date) == 6)
            #expect(calendar.component(.day, from: date) == 15)
        }
    }

    // MARK: - Quarterly

    @Test("Quarterly item generates every 3 months")
    func quarterlyDates() {
        let refDate = makeDate(year: 2026, month: 1, day: 10)

        let item = BudgetItem(
            name: "Quarterly Review",
            type: .expense,
            amount: 500,
            frequency: .quarterly,
            referenceDate: refDate,
            category: .other
        )

        let start = makeDate(year: 2026, month: 1, day: 1)
        let end = makeDate(year: 2026, month: 12, day: 31)

        let dates = DateCalculator.occurrenceDates(for: item, in: start...end)

        #expect(dates.count == 4) // Jan, Apr, Jul, Oct
        let months = dates.map { calendar.component(.month, from: $0) }
        #expect(months.contains(1))
        #expect(months.contains(4))
        #expect(months.contains(7))
        #expect(months.contains(10))
    }

    // MARK: - Effective Amount

    @Test("Effective amount resolves overrides correctly")
    func effectiveAmountWithOverrides() {
        let item = BudgetItem(
            name: "Rent",
            type: .expense,
            amount: 700,
            frequency: .monthly,
            dayOfMonth: 1,
            category: .housing
        )

        let override1 = AmountOverride(
            effectiveDate: makeDate(year: 2026, month: 3, day: 1),
            amount: 750,
            budgetItem: item
        )
        let override2 = AmountOverride(
            effectiveDate: makeDate(year: 2026, month: 6, day: 1),
            amount: 800,
            budgetItem: item
        )

        item.amountOverrides = [override1, override2]

        // Before any override
        #expect(item.effectiveAmount(on: makeDate(year: 2026, month: 1, day: 15)) == 700)

        // After first override
        #expect(item.effectiveAmount(on: makeDate(year: 2026, month: 4, day: 15)) == 750)

        // After second override
        #expect(item.effectiveAmount(on: makeDate(year: 2026, month: 7, day: 15)) == 800)
    }
}
