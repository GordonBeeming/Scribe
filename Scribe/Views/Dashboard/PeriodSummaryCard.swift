import SwiftUI

struct PeriodSummaryCard: View {
    let budgetItems: [BudgetItem]
    let occurrences: [Occurrence]

    @State private var viewModel = DashboardViewModel()

    private var summary: (income: Decimal, expenses: Decimal) {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let endDate = calendar.date(byAdding: .day, value: 13, to: today) ?? today
        return viewModel.periodSummary(
            budgetItems: budgetItems,
            occurrences: occurrences,
            start: today,
            end: endDate
        )
    }

    var body: some View {
        SummaryHeroCard(
            title: "Next 14 Days",
            systemImage: "chart.pie.fill",
            income: summary.income,
            expenses: summary.expenses,
            net: summary.income - summary.expenses
        )
    }
}
