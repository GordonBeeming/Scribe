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
        VStack(alignment: .leading, spacing: 12) {
            Label("Upcoming", systemImage: "clock")
                .font(.headline)
                .foregroundStyle(ScribeTheme.primaryText)

            if displayItems.isEmpty {
                Text("No upcoming items")
                    .font(.subheadline)
                    .foregroundStyle(ScribeTheme.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
            } else {
                ForEach(displayItems) { item in
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
        .padding()
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 16))
    }
}
