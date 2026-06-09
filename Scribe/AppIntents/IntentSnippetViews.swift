import SwiftUI

/// Glass snippet shown alongside Siri's spoken budget summary.
struct BudgetSummarySnippet: View {
    let income: Decimal
    let expenses: Decimal
    let net: Decimal
    var currencyCode: String = "AUD"

    var body: some View {
        VStack(alignment: .leading, spacing: ScribeDesign.Spacing.m) {
            Text("Next 14 Days")
                .font(.headline)
            HStack(spacing: ScribeDesign.Spacing.m) {
                MetricTile(title: "Income", amount: income, type: .income,
                           systemImage: "arrow.down.circle.fill", currencyCode: currencyCode)
                MetricTile(title: "Expenses", amount: expenses, type: .expense,
                           systemImage: "arrow.up.circle.fill", currencyCode: currencyCode)
            }
            HStack {
                Text("Net")
                    .font(.subheadline)
                    .foregroundStyle(ScribeTheme.secondaryText)
                Spacer()
                MoneyText(amount: net, currencyCode: currencyCode, sign: .signed, emphasis: .metric)
            }
        }
        .padding()
    }
}

/// Glass snippet listing the next upcoming expenses.
struct UpcomingExpensesSnippet: View {
    struct Row: Identifiable {
        let id: UUID
        let name: String
        let dueDate: Date
        let amount: Decimal
        let currencyCode: String
    }

    let rows: [Row]

    var body: some View {
        VStack(alignment: .leading, spacing: ScribeDesign.Spacing.s) {
            Text("Due Soon")
                .font(.headline)
            if rows.isEmpty {
                Text("Nothing due soon")
                    .font(.subheadline)
                    .foregroundStyle(ScribeTheme.secondaryText)
            } else {
                ForEach(rows) { row in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(row.name)
                                .font(.subheadline.weight(.medium))
                            Text(row.dueDate, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day())
                                .font(.caption)
                                .foregroundStyle(ScribeTheme.secondaryText)
                        }
                        Spacer()
                        MoneyText(amount: row.amount, currencyCode: row.currencyCode, type: .expense, emphasis: .money)
                    }
                }
            }
        }
        .padding()
    }
}
