import Foundation
import SwiftData

@Observable
final class PeriodViewModel {
    var startDate: Date
    var endDate: Date

    struct DayData: Identifiable {
        let id = UUID()
        let date: Date
        var items: [DayItem]

        var dayTotal: Decimal {
            items.reduce(Decimal.zero) { sum, item in
                sum + (item.budgetItem.type == .income ? item.amount : -item.amount)
            }
        }
    }

    struct DayItem: Identifiable {
        let id: UUID
        let budgetItem: BudgetItem
        let amount: Decimal
        var occurrence: Occurrence?

        var isConfirmed: Bool {
            occurrence?.status == .confirmed
        }

        var isSkipped: Bool {
            occurrence?.status == .skipped
        }
    }

    init() {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let defaultRange = SettingsViewModel.currentDefaultRange()
        self.startDate = today
        self.endDate = defaultRange.endDate(from: today)
    }

    func generateDays(budgetItems: [BudgetItem], occurrences: [Occurrence]) -> [DayData] {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: startDate)
        let end = calendar.startOfDay(for: endDate)

        guard start <= end else { return [] }

        var days: [DayData] = []
        var current = start

        while current <= end {
            var dayItems: [DayItem] = []

            for item in budgetItems where item.isActive {
                let dates = DateCalculator.occurrenceDates(for: item, in: current...current)
                for date in dates {
                    let amount = item.effectiveAmount(on: date)
                    let existingOccurrence = occurrences.first {
                        $0.budgetItem?.id == item.id &&
                        calendar.isDate($0.dueDate, inSameDayAs: date)
                    }
                    dayItems.append(DayItem(
                        id: existingOccurrence?.id ?? UUID(),
                        budgetItem: item,
                        amount: amount,
                        occurrence: existingOccurrence
                    ))
                }
            }

            if !dayItems.isEmpty {
                dayItems.sort { lhs, rhs in
                    // Items with showLast go to the end
                    if lhs.budgetItem.showLast != rhs.budgetItem.showLast {
                        return !lhs.budgetItem.showLast
                    }
                    return lhs.budgetItem.sortOrder < rhs.budgetItem.sortOrder
                }
                days.append(DayData(date: current, items: dayItems))
            }

            guard let next = calendar.date(byAdding: .day, value: 1, to: current) else { break }
            current = next
        }

        return days
    }

    func setQuickRange(_ range: QuickRange) {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        switch range {
        case .thisWeek:
            let weekday = calendar.component(.weekday, from: today)
            let daysFromMonday = (weekday + 5) % 7
            startDate = calendar.date(byAdding: .day, value: -daysFromMonday, to: today) ?? today
            endDate = calendar.date(byAdding: .day, value: 6, to: startDate) ?? today
        case .next7Days:
            startDate = today
            endDate = calendar.date(byAdding: .day, value: 6, to: today) ?? today
        case .next14Days:
            startDate = today
            endDate = calendar.date(byAdding: .day, value: 13, to: today) ?? today
        case .nextMonth:
            startDate = today
            endDate = calendar.date(byAdding: DateComponents(month: 1, day: -1), to: today) ?? today
        case .thisMonth:
            startDate = calendar.date(from: calendar.dateComponents([.year, .month], from: today)) ?? today
            endDate = calendar.date(byAdding: DateComponents(month: 1, day: -1), to: startDate) ?? today
        }
    }

    enum QuickRange: String, CaseIterable, Identifiable {
        case thisWeek = "This Week"
        case next7Days = "Next 7 Days"
        case next14Days = "Next 14 Days"
        case nextMonth = "Next Month"
        case thisMonth = "This Month"

        var id: String { rawValue }
    }
}
