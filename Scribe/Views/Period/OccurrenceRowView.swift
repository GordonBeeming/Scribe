import SwiftUI

struct OccurrenceRowView: View {
    let item: PeriodViewModel.DayItem
    let onConfirm: () -> Void
    let onSkip: () -> Void
    var onTap: (() -> Void)?
    var onAdjustAmount: ((Decimal) -> Void)?

    @State private var showingAmountEditor = false
    @State private var editAmountText = ""

    var exchangeRateCache: ExchangeRateCache = .shared

    private var displayAmount: Decimal {
        item.occurrence?.actualAmount ?? item.amount
    }

    private var hasAmountAdjustment: Bool {
        guard let actual = item.occurrence?.actualAmount else { return false }
        return actual != item.amount
    }

    private var isForeignCurrency: Bool {
        item.budgetItem.currencyCode != exchangeRateCache.baseCurrency
    }

    private var convertedAmount: Decimal? {
        exchangeRateCache.convertToBase(displayAmount, from: item.budgetItem.currencyCode)
    }

    var body: some View {
        HStack {
            Button(action: onConfirm) {
                Image(systemName: statusIcon)
                    .foregroundStyle(statusColor)
                    .imageScale(.large)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                item.isConfirmed ? "Undo confirm" :
                item.isSkipped ? "Undo skip" :
                "Confirm"
            )

            Button {
                onTap?()
            } label: {
                HStack {
                    Text(item.budgetItem.name)
                        .font(.subheadline)
                        .strikethrough(item.isConfirmed || item.isSkipped)
                        .foregroundStyle(item.isSkipped ? ScribeTheme.secondaryText : ScribeTheme.primaryText)

                    Spacer()

                    amountDisplay
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

        }
        .contextMenu {
            if item.isConfirmed {
                Button {
                    editAmountText = "\(displayAmount)"
                    showingAmountEditor = true
                } label: {
                    Label("Edit Amount", systemImage: "pencil")
                }

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
        .popover(isPresented: $showingAmountEditor) {
            amountEditorPopover
        }
    }

    private var amountDisplay: some View {
        VStack(alignment: .trailing, spacing: 2) {
            if isForeignCurrency, let converted = convertedAmount {
                HStack(spacing: 0) {
                    Text("*")
                        .foregroundStyle(ScribeTheme.secondaryText)
                    AmountText(
                        amount: converted,
                        currencyCode: exchangeRateCache.baseCurrency,
                        type: item.budgetItem.type
                    )
                }
                .font(.subheadline.monospacedDigit())

                Text("\(item.budgetItem.currencyCode) \(CurrencyFormatter.formatNumber(displayAmount))")
                    .font(.caption2)
                    .foregroundStyle(ScribeTheme.secondaryText)
            } else {
                AmountText(
                    amount: displayAmount,
                    currencyCode: item.budgetItem.currencyCode,
                    type: item.budgetItem.type
                )
                .font(.subheadline.monospacedDigit())
            }

            if hasAmountAdjustment {
                Text("was \(CurrencyFormatter.format(item.amount, currencyCode: item.budgetItem.currencyCode, signStyle: .none))")
                    .font(.caption2)
                    .foregroundStyle(ScribeTheme.secondaryText)
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

    private var amountEditorPopover: some View {
        VStack(spacing: 12) {
            Text("Actual Amount")
                .font(.headline)

            HStack {
                let formatter = NumberFormatter()
                let _ = formatter.numberStyle = .currency
                let _ = formatter.currencyCode = item.budgetItem.currencyCode
                Text(formatter.currencySymbol ?? "$")
                TextField("Amount", text: $editAmountText)
                    .keyboardType(.decimalPad)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 120)
            }

            if isForeignCurrency {
                Text("Enter amount in \(item.budgetItem.currencyCode)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                Button("Cancel") {
                    showingAmountEditor = false
                }
                .foregroundStyle(.secondary)

                Button("Save") {
                    if let newAmount = Decimal(string: editAmountText) {
                        onAdjustAmount?(newAmount)
                    }
                    showingAmountEditor = false
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .presentationCompactAdaptation(.popover)
    }
}
