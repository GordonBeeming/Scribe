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
        VStack(alignment: .leading, spacing: 12) {
            Label("Period Summary", systemImage: "chart.pie")
                .font(.headline)
                .foregroundStyle(ScribeTheme.primaryText)

            HStack {
                VStack(alignment: .leading) {
                    Text("Income")
                        .font(.caption)
                        .foregroundStyle(ScribeTheme.secondaryText)
                    AmountText(
                        amount: summary.income,
                        currencyCode: "AUD",
                        type: .income,
                        showSign: false
                    )
                    .font(.title3.bold())
                }

                Spacer()

                VStack(alignment: .trailing) {
                    Text("Expenses")
                        .font(.caption)
                        .foregroundStyle(ScribeTheme.secondaryText)
                    AmountText(
                        amount: summary.expenses,
                        currencyCode: "AUD",
                        type: .expense,
                        showSign: false
                    )
                    .font(.title3.bold())
                }
            }

            Divider()

            HStack {
                Text("Net")
                    .font(.subheadline)
                    .foregroundStyle(ScribeTheme.secondaryText)
                Spacer()
                AmountText(
                    amount: summary.income - summary.expenses,
                    currencyCode: "AUD",
                    showSign: true
                )
                .font(.title3.bold())
            }
        }
        .padding()
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 16))
    }
}
