import SwiftUI

struct BudgetItemRowView: View {
    let item: BudgetItem

    var body: some View {
        HStack {
            Image(systemName: item.category.systemImage)
                .foregroundStyle(ScribeTheme.accent)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(item.name)
                        .font(.body)
                    if !item.isActive {
                        Text("Paused")
                            .font(.caption2)
                            .foregroundStyle(ScribeTheme.secondaryText)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                }

                Text(item.frequency.displayName)
                    .font(.caption)
                    .foregroundStyle(ScribeTheme.secondaryText)
            }

            Spacer()

            AmountText(
                amount: item.amount,
                currencyCode: item.currencyCode,
                type: item.type
            )
            .font(.body.monospacedDigit())
        }
        .opacity(item.isActive ? 1.0 : 0.6)
    }
}
