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

                    // Income / Expenses / Net row
                    HStack {
                        VStack(alignment: .leading) {
                            Text("Income")
                                .font(.caption)
                                .foregroundStyle(ScribeTheme.secondaryText)
                            AmountText(
                                amount: group.totalIncome,
                                currencyCode: "AUD",
                                type: .income,
                                showSign: false
                            )
                            .font(.title3.bold())
                        }

                        Spacer()

                        VStack {
                            Text("Expenses")
                                .font(.caption)
                                .foregroundStyle(ScribeTheme.secondaryText)
                            AmountText(
                                amount: group.totalExpenses,
                                currencyCode: "AUD",
                                type: .expense,
                                showSign: false
                            )
                            .font(.title3.bold())
                        }

                        Spacer()

                        VStack(alignment: .trailing) {
                            Text(group.rollingNet != nil ? "Net (rolling)" : "Net")
                                .font(.caption)
                                .foregroundStyle(ScribeTheme.secondaryText)
                            let net = group.rollingNet ?? group.delta
                            Text(CurrencyFormatter.format(net, currencyCode: "AUD", signStyle: .automatic))
                                .font(.title3.monospacedDigit().bold())
                                .foregroundStyle(net >= 0 ? ScribeTheme.success : ScribeTheme.error)
                            if group.totalCount > 0 {
                                Text("\(group.confirmedCount)/\(group.totalCount) confirmed")
                                    .font(.caption2)
                                    .foregroundStyle(ScribeTheme.secondaryText)
                            }
                        }
                    }
                }
            }
            .buttonStyle(.plain)

            // Body - collapsible
            if isExpanded {
                if !group.items.isEmpty {
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

                if group.pendingExpenses > 0 {
                    Divider()
                    HStack {
                        Text("Remaining")
                            .font(.subheadline.bold())
                            .foregroundStyle(ScribeTheme.primaryText)
                        Spacer()
                        Text(CurrencyFormatter.format(group.pendingExpenses, currencyCode: "AUD", signStyle: .none))
                            .font(.subheadline.monospacedDigit().bold())
                            .foregroundStyle(ScribeTheme.primaryText)
                    }
                    .padding(.vertical, 4)
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
