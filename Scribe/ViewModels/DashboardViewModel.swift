import Foundation
import SwiftData
import SwiftUI

@Observable
final class DashboardViewModel {
    var upcomingDays: Int = 7

    struct UpcomingItem: Identifiable {
        let id: UUID
        let budgetItem: BudgetItem
        let dueDate: Date
        let amount: Decimal
        let occurrence: Occurrence?

        var isConfirmed: Bool {
            occurrence?.status == .confirmed
        }

        var isSkipped: Bool {
            occurrence?.status == .skipped
        }

        /// Amount used for balance calculation: actual if confirmed, 0 if skipped, projected if pending
        var effectiveBalanceAmount: Decimal {
            if isSkipped { return 0 }
            if isConfirmed { return occurrence?.actualAmount ?? amount }
            return amount
        }
    }

    func upcomingItems(budgetItems: [BudgetItem], occurrences: [Occurrence], lookbackDays: Int = 0) -> [UpcomingItem] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let startDate = calendar.date(byAdding: .day, value: -lookbackDays, to: today) ?? today
        guard let endDate = calendar.date(byAdding: .day, value: upcomingDays, to: today) else {
            return []
        }

        var items: [UpcomingItem] = []

        for budgetItem in budgetItems where budgetItem.isActive {
            let dates = DateCalculator.occurrenceDates(for: budgetItem, in: startDate...endDate)
            for date in dates {
                if let itemEndDate = budgetItem.endDate, date > calendar.startOfDay(for: itemEndDate) { continue }
                let amount = budgetItem.effectiveAmount(on: date)
                let existingOccurrence = OccurrenceMatching.findOccurrence(
                    for: budgetItem,
                    scheduledDate: date,
                    displayDate: date,
                    in: occurrences
                )
                items.append(UpcomingItem(
                    id: existingOccurrence?.id ?? UUID(),
                    budgetItem: budgetItem,
                    dueDate: date,
                    amount: amount,
                    occurrence: existingOccurrence
                ))
            }
        }

        return items.sorted { $0.dueDate < $1.dueDate }
    }

    func periodSummary(budgetItems: [BudgetItem], occurrences: [Occurrence], start: Date, end: Date) -> (income: Decimal, expenses: Decimal) {
        let calendar = Calendar.current
        let startDay = calendar.startOfDay(for: start)
        let endDay = calendar.startOfDay(for: end)

        var totalIncome: Decimal = 0
        var totalExpenses: Decimal = 0

        for item in budgetItems where item.isActive {
            let dates = DateCalculator.occurrenceDates(for: item, in: startDay...endDay)
            for date in dates {
                if let itemEndDate = item.endDate, date > calendar.startOfDay(for: itemEndDate) { continue }
                let amount = item.effectiveAmount(on: date)
                if item.type == .income {
                    totalIncome += amount
                } else {
                    totalExpenses += amount
                }
            }
        }

        return (income: totalIncome, expenses: totalExpenses)
    }

    // MARK: - Weekly Grouping

    struct WeekGroup: Identifiable {
        var id: Date { startDate }
        let label: String
        let startDate: Date
        let endDate: Date
        let items: [UpcomingItem]
        let totalIncome: Decimal
        let totalExpenses: Decimal
        /// Cumulative net carried across weeks (this week's `delta` plus every prior week's),
        /// seeded at 0 at the current week. Non-nil only when the rolling-net setting is on.
        let rollingNet: Decimal?
        let confirmedCount: Int
        let totalCount: Int
        /// Total amount of pending (unconfirmed, not skipped) expenses still to come, in base currency.
        let pendingExpenses: Decimal
        /// This week's standalone net (income − expenses).
        var delta: Decimal { totalIncome - totalExpenses }
    }

    struct MonthlySummary: Identifiable {
        let id: UUID
        let label: String
        let totalIncome: Decimal
        let totalExpenses: Decimal
        var delta: Decimal { totalIncome - totalExpenses }
    }

    func weeklyGroups(
        budgetItems: [BudgetItem],
        occurrences: [Occurrence],
        anchor: DashboardSectionAnchor,
        range: DefaultRange,
        holidays: Set<Date>,
        exchangeRates: [String: Double] = [:],
        baseCurrency: String = "AUD",
        rollingNet: Bool = false
    ) -> [WeekGroup] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let endDate = range.endDate(from: today)

        // Resolve anchor weekday
        let anchorWeekday: Int
        switch anchor {
        case .fixedDay(let weekday):
            anchorWeekday = weekday
        case .linkedIncome(let budgetItemID):
            if let item = budgetItems.first(where: { $0.id == budgetItemID }) {
                // Derive weekday from the item's next display date (after adjustments + reflection)
                let dates = DateCalculator.occurrenceDates(for: item, in: today...endDate)
                if let firstDate = dates.first {
                    let displayDate = DateCalculator.budgetDisplayDate(for: item, scheduledDate: firstDate, holidays: holidays)
                    anchorWeekday = calendar.component(.weekday, from: displayDate)
                } else {
                    anchorWeekday = 2 // default Monday
                }
            } else {
                anchorWeekday = 2
            }
        case .fixedDayOfMonth:
            anchorWeekday = 2 // weekly doesn't use day-of-month, default Monday
        }

        // Find most recent anchor weekday on or before today
        var weekStart = today
        let todayWeekday = calendar.component(.weekday, from: today)
        var diff = todayWeekday - anchorWeekday
        if diff < 0 { diff += 7 }
        weekStart = calendar.date(byAdding: .day, value: -diff, to: today) ?? today

        // Generate week boundaries covering the range
        var preliminaryGroups: [(start: Date, end: Date, items: [UpcomingItem])] = []
        var currentStart = weekStart

        while currentStart <= endDate {
            let currentEnd = calendar.date(byAdding: .day, value: 6, to: currentStart) ?? currentStart

            // Collect budget items for this week
            var weekItems: [UpcomingItem] = []
            let queryStart = calendar.date(byAdding: .day, value: -1, to: currentStart) ?? currentStart
            let queryEnd = calendar.date(byAdding: .day, value: 1, to: currentEnd) ?? currentEnd

            for item in budgetItems where item.isActive {
                let dates = DateCalculator.occurrenceDates(for: item, in: queryStart...queryEnd)
                for date in dates {
                    if let itemEndDate = item.endDate, date > calendar.startOfDay(for: itemEndDate) { continue }
                    let displayDate = DateCalculator.budgetDisplayDate(for: item, scheduledDate: date, holidays: holidays)
                    guard displayDate >= currentStart && displayDate <= currentEnd else { continue }
                    let amount = item.effectiveAmount(on: date)
                    let existingOccurrence = OccurrenceMatching.findOccurrence(
                        for: item,
                        scheduledDate: date,
                        displayDate: displayDate,
                        in: occurrences
                    )
                    weekItems.append(UpcomingItem(
                        id: existingOccurrence?.id ?? UUID(),
                        budgetItem: item,
                        dueDate: displayDate,
                        amount: amount,
                        occurrence: existingOccurrence
                    ))
                }
            }

            weekItems.sort { $0.dueDate < $1.dueDate }

            preliminaryGroups.append((start: currentStart, end: currentEnd, items: weekItems))

            guard let nextStart = calendar.date(byAdding: .day, value: 7, to: currentStart) else { break }
            currentStart = nextStart
        }

        // Cumulative net carried across weeks (only surfaced when the rolling-net setting is on).
        var cumulativeNet: Decimal = 0

        let formatter = DateFormatter()
        formatter.dateFormat = "EEE d MMM"

        var groups: [WeekGroup] = []
        for pg in preliminaryGroups {
            let totalIncome = pg.items.filter { $0.budgetItem.type == .income }
                .reduce(Decimal.zero) { $0 + toBase($1.effectiveBalanceAmount, from: $1.budgetItem.currencyCode, rates: exchangeRates, base: baseCurrency) }
            let totalExpenses = pg.items.filter { $0.budgetItem.type == .expense }
                .reduce(Decimal.zero) { $0 + toBase($1.effectiveBalanceAmount, from: $1.budgetItem.currencyCode, rates: exchangeRates, base: baseCurrency) }

            let weekNet = totalIncome - totalExpenses
            cumulativeNet += weekNet

            let pendingExpenses = pg.items
                .filter { $0.budgetItem.type == .expense && !$0.isConfirmed && !$0.isSkipped }
                .reduce(Decimal.zero) { $0 + toBase($1.amount, from: $1.budgetItem.currencyCode, rates: exchangeRates, base: baseCurrency) }

            let label = "\(formatter.string(from: pg.start)) – \(formatter.string(from: pg.end))"

            groups.append(WeekGroup(
                label: label,
                startDate: pg.start,
                endDate: pg.end,
                items: pg.items,
                totalIncome: totalIncome,
                totalExpenses: totalExpenses,
                rollingNet: rollingNet ? cumulativeNet : nil,
                confirmedCount: pg.items.filter(\.isConfirmed).count,
                totalCount: pg.items.count,
                pendingExpenses: pendingExpenses
            ))
        }

        return groups
    }

    func monthlySummary(
        budgetItems: [BudgetItem],
        occurrences: [Occurrence],
        anchor: DashboardSectionAnchor,
        holidays: Set<Date>,
        exchangeRates: [String: Double] = [:],
        baseCurrency: String = "AUD"
    ) -> MonthlySummary {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        // Resolve anchor day of month
        let anchorDay: Int
        switch anchor {
        case .fixedDayOfMonth(let day):
            anchorDay = day
        case .linkedIncome(let budgetItemID):
            if let item = budgetItems.first(where: { $0.id == budgetItemID }) {
                anchorDay = item.dayOfMonth ?? calendar.component(.day, from: item.referenceDate ?? today)
            } else {
                anchorDay = 1
            }
        case .fixedDay:
            anchorDay = 1
        }

        // Find current month boundary
        let currentDay = calendar.component(.day, from: today)
        var startComponents = calendar.dateComponents([.year, .month], from: today)
        if currentDay < anchorDay {
            // Go back one month
            if startComponents.month == 1 {
                startComponents.month = 12
                startComponents.year = (startComponents.year ?? 0) - 1
            } else {
                startComponents.month = (startComponents.month ?? 1) - 1
            }
        }
        let daysInMonth = calendar.range(of: .day, in: .month, for: calendar.date(from: startComponents) ?? today)?.count ?? 28
        startComponents.day = min(anchorDay, daysInMonth)
        let monthStart = calendar.date(from: startComponents) ?? today

        // End is one month later minus 1 day
        var endComponents = startComponents
        if endComponents.month == 12 {
            endComponents.month = 1
            endComponents.year = (endComponents.year ?? 0) + 1
        } else {
            endComponents.month = (endComponents.month ?? 1) + 1
        }
        let daysInEndMonth = calendar.range(of: .day, in: .month, for: calendar.date(from: endComponents) ?? today)?.count ?? 28
        endComponents.day = min(anchorDay, daysInEndMonth)
        let monthEndRaw = calendar.date(from: endComponents) ?? today
        let monthEnd = calendar.date(byAdding: .day, value: -1, to: monthEndRaw) ?? monthEndRaw

        var totalIncome: Decimal = 0
        var totalExpenses: Decimal = 0

        let queryStart = calendar.date(byAdding: .day, value: -1, to: monthStart) ?? monthStart
        let queryEnd = calendar.date(byAdding: .day, value: 1, to: monthEnd) ?? monthEnd

        for item in budgetItems where item.isActive {
            let dates = DateCalculator.occurrenceDates(for: item, in: queryStart...queryEnd)
            for date in dates {
                if let itemEndDate = item.endDate, date > calendar.startOfDay(for: itemEndDate) { continue }
                let displayDate = DateCalculator.budgetDisplayDate(for: item, scheduledDate: date, holidays: holidays)
                guard displayDate >= monthStart && displayDate <= monthEnd else { continue }
                let rawAmount = item.effectiveAmount(on: date)
                let amount = toBase(rawAmount, from: item.currencyCode, rates: exchangeRates, base: baseCurrency)
                if item.type == .income {
                    totalIncome += amount
                } else {
                    totalExpenses += amount
                }
            }
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM"
        let label = "\(formatter.string(from: monthStart)) – \(formatter.string(from: monthEnd))"

        return MonthlySummary(
            id: UUID(),
            label: label,
            totalIncome: totalIncome,
            totalExpenses: totalExpenses
        )
    }

    /// Convert `amount` from `code` into `base`, falling back to raw `amount` when rates aren't loaded or the currency is unknown.
    /// Callers that don't provide rates (e.g. tests, pre-load states) keep the original pass-through behavior.
    private func toBase(_ amount: Decimal, from code: String, rates: [String: Double], base: String) -> Decimal {
        ExchangeRateCache.convertToBase(amount, from: code, rates: rates, baseCurrency: base) ?? amount
    }
}
