import SwiftUI

struct MonthlySummaryCard: View {
    let summary: DashboardViewModel.MonthlySummary

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(summary.label, systemImage: "calendar")
                .font(.headline)
                .foregroundStyle(ScribeTheme.primaryText)

            HStack {
                VStack(alignment: .leading) {
                    Text("Income")
                        .font(.caption)
                        .foregroundStyle(ScribeTheme.secondaryText)
                    AmountText(
                        amount: summary.totalIncome,
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
                        amount: summary.totalExpenses,
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
                    amount: summary.delta,
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
