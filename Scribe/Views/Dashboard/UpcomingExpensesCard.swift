import SwiftUI

struct UpcomingExpensesCard: View {
    let items: [DashboardViewModel.UpcomingItem]
    let onConfirm: (DashboardViewModel.UpcomingItem) -> Void
    let onSkip: (DashboardViewModel.UpcomingItem) -> Void
    var onTap: ((DashboardViewModel.UpcomingItem) -> Void)?
    var onAdjustAmount: ((DashboardViewModel.UpcomingItem, Decimal) -> Void)?

    private var displayItems: [DashboardViewModel.UpcomingItem] {
        Array(items.prefix(8))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ScribeDesign.Spacing.m) {
            HStack(spacing: ScribeDesign.Spacing.s) {
                Image(systemName: "clock.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(ScribeTheme.accent)
                Text("Upcoming")
                    .font(ScribeDesign.Font.cardTitle)
                    .foregroundStyle(ScribeTheme.primaryText)
                Spacer(minLength: 0)
            }

            if displayItems.isEmpty {
                Text("Nothing due soon")
                    .font(.subheadline)
                    .foregroundStyle(ScribeTheme.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, ScribeDesign.Spacing.s)
            } else {
                ForEach(Array(displayItems.enumerated()), id: \.element.id) { index, item in
                    if index > 0 {
                        Divider().overlay(ScribeTheme.secondaryText.opacity(0.12))
                    }
                    UpcomingItemRow(
                        item: item,
                        onConfirm: { onConfirm(item) },
                        onSkip: { onSkip(item) },
                        onTap: { onTap?(item) },
                        onAdjustAmount: { newAmount in onAdjustAmount?(item, newAmount) }
                    )
                }
            }
        }
        .scribeCard()
    }
}
