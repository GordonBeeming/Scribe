import SwiftUI

struct WeeklyBudgetCard: View {
    let group: DashboardViewModel.WeekGroup
    let onConfirm: (DashboardViewModel.UpcomingItem) -> Void
    let onSkip: (DashboardViewModel.UpcomingItem) -> Void
    var onTap: ((DashboardViewModel.UpcomingItem) -> Void)?
    var onAdjustAmount: ((DashboardViewModel.UpcomingItem, Decimal) -> Void)?
    var isCurrentWeek: Bool = false

    @State private var isExpanded: Bool = true

    private var net: Decimal { group.rollingNet ?? group.delta }
    private var netLabel: String { group.rollingNet != nil ? "Net (rolling)" : "Net" }

    var body: some View {
        VStack(alignment: .leading, spacing: ScribeDesign.Spacing.m) {
            header
            if isExpanded {
                if !group.items.isEmpty {
                    Divider().overlay(ScribeTheme.secondaryText.opacity(0.15))
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
                    Divider().overlay(ScribeTheme.secondaryText.opacity(0.15))
                    HStack {
                        Text("Remaining")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(ScribeTheme.primaryText)
                        Spacer()
                        Text(CurrencyFormatter.format(group.pendingExpenses, currencyCode: "AUD", signStyle: .none))
                            .font(ScribeDesign.Font.money)
                            .foregroundStyle(ScribeTheme.primaryText)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .scribeCard()
        .overlay {
            if isCurrentWeek {
                RoundedRectangle(cornerRadius: ScribeDesign.Radius.card)
                    .strokeBorder(ScribeTheme.accent.opacity(0.55), lineWidth: 1.5)
            }
        }
        .onAppear { isExpanded = isCurrentWeek }
    }

    private var header: some View {
        Button {
            withAnimation(.snappy) { isExpanded.toggle() }
        } label: {
            VStack(alignment: .leading, spacing: ScribeDesign.Spacing.m) {
                HStack(spacing: ScribeDesign.Spacing.s) {
                    Text(group.label)
                        .font(ScribeDesign.Font.cardTitle)
                        .foregroundStyle(ScribeTheme.primaryText)
                    if isCurrentWeek {
                        Text("This week")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(ScribeTheme.accent)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(ScribeTheme.accent.opacity(0.16), in: .capsule)
                    }
                    Spacer()
                    if group.totalCount > 0 {
                        Text("\(group.confirmedCount)/\(group.totalCount)")
                            .font(.caption.monospacedDigit().weight(.medium))
                            .foregroundStyle(ScribeTheme.secondaryText)
                    }
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(ScribeTheme.secondaryText)
                        .rotationEffect(.degrees(isExpanded ? 0 : -90))
                }

                HStack(alignment: .top, spacing: ScribeDesign.Spacing.m) {
                    miniStat("Income", group.totalIncome, type: .income, alignment: .leading)
                    miniStat("Expenses", group.totalExpenses, type: .expense, alignment: .leading)
                    miniStat(netLabel, net, type: nil, alignment: .trailing)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func miniStat(_ title: String, _ amount: Decimal, type: ItemType?, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 2) {
            Text(title)
                .font(ScribeDesign.Font.label)
                .foregroundStyle(ScribeTheme.secondaryText)
                .lineLimit(1)
            MoneyText(
                amount: amount,
                currencyCode: "AUD",
                type: type,
                sign: type == nil ? .signed : .unsigned,
                emphasis: .money
            )
            .lineLimit(1)
            .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: Alignment(horizontal: alignment, vertical: .center))
    }
}
