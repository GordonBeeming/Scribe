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
    }

    func upcomingItems(budgetItems: [BudgetItem], occurrences: [Occurrence]) -> [UpcomingItem] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        guard let endDate = calendar.date(byAdding: .day, value: upcomingDays, to: today) else {
            return []
        }

        var items: [UpcomingItem] = []

        for budgetItem in budgetItems where budgetItem.isActive {
            let dates = DateCalculator.occurrenceDates(for: budgetItem, in: today...endDate)
            for date in dates {
                let amount = budgetItem.effectiveAmount(on: date)
                let existingOccurrence = occurrences.first {
                    $0.budgetItem?.id == budgetItem.id &&
                    calendar.isDate($0.dueDate, inSameDayAs: date)
                }
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
        let id: UUID
        let label: String
        let startDate: Date
        let endDate: Date
        let items: [UpcomingItem]
        let adjustments: [QuickAdjustment]
        let totalIncome: Decimal
        let totalExpenses: Decimal
        let adjustmentIncome: Decimal
        let adjustmentExpenses: Decimal
        let carryOver: Decimal
        let closingBalance: Decimal
        let hasBalanceReset: Bool
        var delta: Decimal { totalIncome - totalExpenses + adjustmentIncome - adjustmentExpenses }
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
        quickAdjustments: [QuickAdjustment],
        anchor: DashboardSectionAnchor,
        range: DefaultRange,
        holidays: Set<Date>
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

        // Find the most recent balance reset to determine starting point
        let allResets = quickAdjustments
            .filter { $0.adjustmentType == .balanceReset }
            .sorted { $0.date < $1.date }
        let lastReset = allResets.last

        // Generate week boundaries covering the range
        var preliminaryGroups: [(start: Date, end: Date, items: [UpcomingItem], adjustments: [QuickAdjustment])] = []
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
                    let displayDate = DateCalculator.budgetDisplayDate(for: item, scheduledDate: date, holidays: holidays)
                    guard displayDate >= currentStart && displayDate <= currentEnd else { continue }
                    let amount = item.effectiveAmount(on: date)
                    let existingOccurrence = occurrences.first {
                        $0.budgetItem?.id == item.id &&
                        calendar.isDate($0.dueDate, inSameDayAs: date)
                    }
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

            // Collect quick adjustments for this week (non-reset)
            let weekAdjustments = quickAdjustments.filter { adj in
                adj.adjustmentType != .balanceReset &&
                calendar.startOfDay(for: adj.date) >= currentStart &&
                calendar.startOfDay(for: adj.date) <= currentEnd
            }.sorted { $0.date < $1.date }

            preliminaryGroups.append((start: currentStart, end: currentEnd, items: weekItems, adjustments: weekAdjustments))

            guard let nextStart = calendar.date(byAdding: .day, value: 7, to: currentStart) else { break }
            currentStart = nextStart
        }

        // Compute running balance across weeks
        var runningBalance: Decimal = 0

        // If there's a balance reset, start from that amount
        if let reset = lastReset {
            runningBalance = reset.amount
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "EEE d MMM"

        var groups: [WeekGroup] = []
        for pg in preliminaryGroups {
            let totalIncome = pg.items.filter { $0.budgetItem.type == .income }.reduce(Decimal.zero) { $0 + $1.amount }
            let totalExpenses = pg.items.filter { $0.budgetItem.type == .expense }.reduce(Decimal.zero) { $0 + $1.amount }
            let adjIncome = pg.adjustments.filter { $0.adjustmentType == .income }.reduce(Decimal.zero) { $0 + $1.amount }
            let adjExpenses = pg.adjustments.filter { $0.adjustmentType == .expense }.reduce(Decimal.zero) { $0 + $1.amount }

            // Check for balance resets within this week
            let weekResets = allResets.filter { reset in
                calendar.startOfDay(for: reset.date) >= pg.start &&
                calendar.startOfDay(for: reset.date) <= pg.end
            }
            let hasReset = !weekResets.isEmpty
            if let latestWeekReset = weekResets.last {
                runningBalance = latestWeekReset.amount
            }

            let carryOver = runningBalance
            let weekNet = totalIncome - totalExpenses + adjIncome - adjExpenses
            let closingBalance = carryOver + weekNet

            let label = "\(formatter.string(from: pg.start)) – \(formatter.string(from: pg.end))"

            groups.append(WeekGroup(
                id: UUID(),
                label: label,
                startDate: pg.start,
                endDate: pg.end,
                items: pg.items,
                adjustments: pg.adjustments,
                totalIncome: totalIncome,
                totalExpenses: totalExpenses,
                adjustmentIncome: adjIncome,
                adjustmentExpenses: adjExpenses,
                carryOver: carryOver,
                closingBalance: closingBalance,
                hasBalanceReset: hasReset
            ))

            runningBalance = closingBalance
        }

        return groups
    }

    func monthlySummary(
        budgetItems: [BudgetItem],
        occurrences: [Occurrence],
        anchor: DashboardSectionAnchor,
        holidays: Set<Date>
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
                let displayDate = DateCalculator.budgetDisplayDate(for: item, scheduledDate: date, holidays: holidays)
                guard displayDate >= monthStart && displayDate <= monthEnd else { continue }
                let amount = item.effectiveAmount(on: date)
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
}
