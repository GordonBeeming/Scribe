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
}
