import SwiftUI

struct UpcomingItemRow: View {
    let item: DashboardViewModel.UpcomingItem
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

            if item.isConfirmed {
                Button {
                    editAmountText = "\(displayAmount)"
                    showingAmountEditor = true
                } label: {
                    amountDisplay
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showingAmountEditor) {
                    amountEditorPopover
                }
            } else {
                amountDisplay
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            onTap?()
        }
    }

    private var amountDisplay: some View {
        VStack(alignment: .trailing, spacing: 2) {
            if isForeignCurrency, let converted = convertedAmount {
                // Show converted base currency amount with * to indicate estimate
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

                // Show original foreign amount as "USD 10.00"
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
