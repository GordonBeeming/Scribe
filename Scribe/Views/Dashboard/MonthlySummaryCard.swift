import SwiftUI

struct MonthlySummaryCard: View {
    let summary: DashboardViewModel.MonthlySummary

    var body: some View {
        SummaryHeroCard(
            title: summary.label,
            systemImage: "calendar",
            income: summary.totalIncome,
            expenses: summary.totalExpenses,
            net: summary.delta
        )
    }
}
