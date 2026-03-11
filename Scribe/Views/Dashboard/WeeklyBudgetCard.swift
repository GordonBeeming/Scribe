import SwiftUI

struct WeeklyBudgetCard: View {
    let group: DashboardViewModel.WeekGroup
    let onConfirm: (DashboardViewModel.UpcomingItem) -> Void
    let onSkip: (DashboardViewModel.UpcomingItem) -> Void
    var onTap: ((DashboardViewModel.UpcomingItem) -> Void)?
    var onAdjustAmount: ((DashboardViewModel.UpcomingItem, Decimal) -> Void)?
    var isCurrentWeek: Bool = false

    @State private var isExpanded: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header - always visible
            Button {
                withAnimation { isExpanded.toggle() }
            } label: {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(group.label)
                            .font(.headline)
                            .foregroundStyle(ScribeTheme.primaryText)
                        Spacer()
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .foregroundStyle(ScribeTheme.secondaryText)
                    }

                    // Balance row
                    HStack {
                        VStack(alignment: .leading) {
                            Text("Opening")
                                .font(.caption2)
                                .foregroundStyle(ScribeTheme.secondaryText)
                            AmountText(
                                amount: group.carryOver,
                                currencyCode: "AUD",
                                showSign: false
                            )
                            .font(.caption.monospacedDigit().bold())
                        }

                        Spacer()

                        VStack(alignment: .trailing) {
                            Text("Closing")
                                .font(.caption2)
                                .foregroundStyle(ScribeTheme.secondaryText)
                            Text(CurrencyFormatter.format(group.closingBalance, currencyCode: "AUD", signStyle: .automatic))
                                .font(.subheadline.monospacedDigit().bold())
                                .foregroundStyle(group.closingBalance >= 0 ? ScribeTheme.success : ScribeTheme.error)
                        }
                    }

                    // Income / Expenses / Net row
                    HStack {
                        VStack(alignment: .leading) {
                            Text("Income")
                                .font(.caption)
                                .foregroundStyle(ScribeTheme.secondaryText)
                            let totalInc = group.totalIncome + group.adjustmentIncome
                            AmountText(
                                amount: totalInc,
                                currencyCode: "AUD",
                                type: .income,
                                showSign: false
                            )
                            .font(.caption.bold())
                        }

                        Spacer()

                        VStack {
                            Text("Expenses")
                                .font(.caption)
                                .foregroundStyle(ScribeTheme.secondaryText)
                            let totalExp = group.totalExpenses + group.adjustmentExpenses
                            AmountText(
                                amount: totalExp,
                                currencyCode: "AUD",
                                type: .expense,
                                showSign: false
                            )
                            .font(.caption.bold())
                        }

                        Spacer()

                        VStack(alignment: .trailing) {
                            Text("Net")
                                .font(.caption)
                                .foregroundStyle(ScribeTheme.secondaryText)
                            AmountText(
                                amount: group.delta,
                                currencyCode: "AUD",
                                showSign: true
                            )
                            .font(.caption.bold())
                        }
                    }
                }
            }
            .buttonStyle(.plain)

            // Body - collapsible
            if isExpanded {
                if !group.items.isEmpty || !group.adjustments.isEmpty {
                    Divider()
                }

                ForEach(group.items) { item in
                    UpcomingItemRow(
                        item: item,
                        onConfirm: { onConfirm(item) },
                        onSkip: { onSkip(item) },
                        onTap: { onTap?(item) },
                        onAdjustAmount: { newAmount in onAdjustAmount?(item, newAmount) }
                    )
                }

                // Show quick adjustments
                ForEach(group.adjustments) { adjustment in
                    HStack(spacing: 8) {
                        Image(systemName: adjustment.adjustmentType.systemImage)
                            .foregroundStyle(adjustment.adjustmentType == .income ? ScribeTheme.success : ScribeTheme.error)
                            .font(.caption)

                        VStack(alignment: .leading) {
                            Text(adjustment.name)
                                .font(.subheadline)
                                .lineLimit(1)
                            Text(adjustment.date, format: .dateTime.weekday(.abbreviated).day().month())
                                .font(.caption2)
                                .foregroundStyle(ScribeTheme.secondaryText)
                        }

                        Spacer()

                        Text(CurrencyFormatter.format(
                            adjustment.amount,
                            currencyCode: adjustment.currencyCode,
                            signStyle: adjustment.adjustmentType == .income ? .alwaysPositive : .alwaysNegative
                        ))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(adjustment.adjustmentType == .income ? ScribeTheme.success : ScribeTheme.error)
                    }
                    .padding(.vertical, 2)
                }

                if group.hasBalanceReset {
                    HStack {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.caption)
                        Text("Balance adjusted this week")
                            .font(.caption)
                    }
                    .foregroundStyle(ScribeTheme.secondaryText)
                    .padding(.vertical, 2)
                }
            }
        }
        .padding()
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 16))
        .onAppear {
            isExpanded = isCurrentWeek
        }
    }
}
