import SwiftUI

struct OccurrenceRowView: View {
    let item: PeriodViewModel.DayItem
    let onConfirm: () -> Void
    let onSkip: () -> Void
    var onTap: (() -> Void)?

    var body: some View {
        HStack {
            Button(action: onConfirm) {
                Image(systemName: statusIcon)
                    .foregroundStyle(statusColor)
                    .imageScale(.large)
            }
            .buttonStyle(.plain)

            Text(item.budgetItem.name)
                .font(.subheadline)
                .strikethrough(item.isConfirmed || item.isSkipped)
                .foregroundStyle(item.isSkipped ? ScribeTheme.secondaryText : ScribeTheme.primaryText)

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
        .contextMenu {
            if item.isConfirmed {
                Button {
                    onConfirm()
                } label: {
                    Label("Undo Confirm", systemImage: "arrow.uturn.backward")
                }
            } else if item.isSkipped {
                Button {
                    onSkip()
                } label: {
                    Label("Undo Skip", systemImage: "arrow.uturn.backward")
                }
            } else {
                Button {
                    onConfirm()
                } label: {
                    Label("Confirm", systemImage: "checkmark.circle")
                }

                Button {
                    onSkip()
                } label: {
                    Label("Skip", systemImage: "arrow.uturn.right")
                }
            }
        }
    }

    private var statusIcon: String {
        if item.isConfirmed { return "checkmark.circle.fill" }
        if item.isSkipped { return "arrow.uturn.right.circle" }
        return "circle"
    }

    private var statusColor: Color {
        if item.isConfirmed { return ScribeTheme.success }
        if item.isSkipped { return ScribeTheme.secondaryText }
        return ScribeTheme.secondaryText
    }
}
