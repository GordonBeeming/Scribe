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
                    if let endDate = item.endDate {
                        Text("Closed \(endDate, format: .dateTime.day().month())")
                            .font(.caption2)
                            .foregroundStyle(ScribeTheme.error)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.ultraThinMaterial, in: Capsule())
                    } else if !item.isActive {
                        Text("Paused")
                            .font(.caption2)
                            .foregroundStyle(ScribeTheme.secondaryText)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                }

                HStack(spacing: 4) {
                    Text(item.frequency.displayName)
                    if let dayOfMonth = item.dayOfMonth {
                        Text("· Day \(dayOfMonth)")
                    } else if let refDate = item.referenceDate {
                        Text("· \(refDate, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated))")
                    }
                }
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
        .opacity(item.isActive && item.endDate == nil ? 1.0 : 0.6)
    }
}
