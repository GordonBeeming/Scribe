import SwiftUI

/// The focal summary surface used by the monthly and period dashboard cards.
/// Leads with the net figure as a single large metric, with income/expenses as
/// supporting tiles. Rendered as a tinted glass hero on the screen gradient.
struct SummaryHeroCard: View {
    let title: String
    var systemImage: String = "calendar"
    let income: Decimal
    let expenses: Decimal
    let net: Decimal
    var currencyCode: String = "AUD"

    var body: some View {
        VStack(alignment: .leading, spacing: ScribeDesign.Spacing.l) {
            HStack(spacing: ScribeDesign.Spacing.s) {
                Image(systemName: systemImage)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(ScribeTheme.accent)
                Text(title)
                    .font(ScribeDesign.Font.cardTitle)
                    .foregroundStyle(ScribeTheme.primaryText)
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Net")
                    .font(ScribeDesign.Font.label)
                    .foregroundStyle(ScribeTheme.secondaryText)
                MoneyText(
                    amount: net,
                    currencyCode: currencyCode,
                    sign: .signed,
                    emphasis: .metricLarge
                )
            }

            HStack(spacing: ScribeDesign.Spacing.m) {
                MetricTile(title: "Income", amount: income, type: .income,
                           systemImage: "arrow.down.circle.fill", currencyCode: currencyCode)
                MetricTile(title: "Expenses", amount: expenses, type: .expense,
                           systemImage: "arrow.up.circle.fill", currencyCode: currencyCode)
            }
        }
        .scribeHeroCard()
    }
}

/// A supporting metric inside a glass card. Uses an opaque-ish surface fill
/// rather than a second glass layer, which would muddy the hero's refraction.
struct MetricTile: View {
    let title: String
    let amount: Decimal
    var type: ItemType?
    var systemImage: String
    var currencyCode: String = "AUD"

    var body: some View {
        VStack(alignment: .leading, spacing: ScribeDesign.Spacing.xs) {
            HStack(spacing: ScribeDesign.Spacing.xs) {
                Image(systemName: systemImage)
                    .font(.caption)
                    .foregroundStyle(tint)
                Text(title)
                    .font(ScribeDesign.Font.label)
                    .foregroundStyle(ScribeTheme.secondaryText)
            }
            MoneyText(
                amount: amount,
                currencyCode: currencyCode,
                type: type,
                sign: .unsigned,
                emphasis: .metric
            )
            .lineLimit(1)
            .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, ScribeDesign.Spacing.s)
        .padding(.horizontal, ScribeDesign.Spacing.m)
        .background(ScribeTheme.surface.opacity(0.45), in: .rect(cornerRadius: ScribeDesign.Radius.row))
    }

    private var tint: Color {
        if let type { return ScribeTheme.amountColor(for: type) }
        return ScribeTheme.accent
    }
}
