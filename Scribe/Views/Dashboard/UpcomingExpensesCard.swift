import SwiftUI

struct UpcomingExpensesCard: View {
    let items: [DashboardViewModel.UpcomingItem]
    let onConfirm: (DashboardViewModel.UpcomingItem) -> Void
    let onSkip: (DashboardViewModel.UpcomingItem) -> Void
    var onTap: ((DashboardViewModel.UpcomingItem) -> Void)?

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
                        onTap: { onTap?(item) }
                    )
                }
            }
        }
        .padding()
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 16))
    }
}

private struct UpcomingItemRow: View {
    let item: DashboardViewModel.UpcomingItem
    let onConfirm: () -> Void
    let onSkip: () -> Void
    var onTap: (() -> Void)?

    var body: some View {
        HStack {
            Button(action: onConfirm) {
                Image(systemName: item.isConfirmed ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(item.isConfirmed ? ScribeTheme.success : ScribeTheme.secondaryText)
                    .imageScale(.large)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading) {
                Text(item.budgetItem.name)
                    .font(.subheadline)
                    .strikethrough(item.isConfirmed)

                Text(item.dueDate, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day())
                    .font(.caption)
                    .foregroundStyle(ScribeTheme.secondaryText)
            }

            Spacer()

            AmountText(
                amount: item.amount,
                currencyCode: item.budgetItem.currencyCode,
                type: item.budgetItem.type
            )
            .font(.subheadline.monospacedDigit())
        }
        .contentShape(Rectangle())
        .onTapGesture {
            onTap?()
        }
    }
}
