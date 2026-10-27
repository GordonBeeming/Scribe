import SwiftUI

struct WeeklyInsightsCard: View {
    let summary: DashboardViewModel.ReconciliationSummary
    let currencyCode: String
    var sectionLabel: String?

    private var overdueDescription: String {
        switch summary.overdueCount {
        case 0: "No earlier payments left unchecked"
        case 1: "1 earlier payment still unchecked"
        default: "\(summary.overdueCount) earlier payments still unchecked"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ScribeDesign.Spacing.l) {
            VStack(alignment: .leading, spacing: ScribeDesign.Spacing.xs) {
                Label("Weekly check-in", systemImage: "checkmark.circle")
                    .font(ScribeDesign.Font.cardTitle)
                if let sectionLabel {
                    Text(sectionLabel)
                        .font(.subheadline.weight(.semibold))
                }
                Text(summary.weekLabel)
                    .font(ScribeDesign.Font.label)
                    .foregroundStyle(ScribeTheme.secondaryText)
            }

            VStack(alignment: .leading, spacing: ScribeDesign.Spacing.xs) {
                Text("Expenses remaining")
                    .font(.subheadline)
                    .foregroundStyle(ScribeTheme.secondaryText)
                MoneyText(amount: summary.remainingExpenses, currencyCode: currencyCode,
                          sign: .unsigned, emphasis: .metric, colored: false)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .accessibilityIdentifier("dashboard.remaining")
            }

            Divider()

            if summary.totalCount > 0 {
                VStack(alignment: .leading, spacing: ScribeDesign.Spacing.s) {
                    Text("\(summary.reviewedCount) of \(summary.totalCount) payments reviewed")
                        .font(.subheadline)
                        .accessibilityIdentifier("dashboard.reviewed-count")
                    ProgressView(value: Double(summary.reviewedCount), total: Double(summary.totalCount))
                        .tint(ScribeTheme.success)
                        .accessibilityLabel("Payments reviewed this week")
                }
            } else {
                Text("No payments scheduled this week")
                    .font(.subheadline)
                    .foregroundStyle(ScribeTheme.secondaryText)
            }

            Label {
                Text(overdueDescription)
            } icon: {
                Image(systemName: summary.overdueCount == 0 ? "checkmark.circle" : "clock")
                    .foregroundStyle(summary.overdueCount == 0 ? ScribeTheme.success : ScribeTheme.error)
            }
            .font(.subheadline)
        }
        .foregroundStyle(ScribeTheme.primaryText)
        .frame(maxWidth: .infinity, alignment: .leading)
        .scribeCard()
    }
}
