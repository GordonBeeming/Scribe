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

    private var isOverdue: Bool {
        !item.isConfirmed && item.dueDate < Calendar.current.startOfDay(for: Date())
    }

    private var isIncome: Bool {
        item.budgetItem.type == .income
    }

    // MARK: - Avatar / confirm affordance

    /// The category tint — income reads as success-green, expenses as the adaptive
    /// brand indigo (the periwinkle accent is too low-contrast on light glass).
    private var categoryTint: Color {
        isIncome ? ScribeTheme.success : ScribeTheme.primary
    }

    private var avatarIcon: String {
        if item.isConfirmed { return isIncome ? "arrow.down" : "checkmark" }
        if item.isSkipped { return "arrow.uturn.right" }
        return item.budgetItem.category.systemImage
    }

    private var avatarFill: Color {
        if item.isConfirmed { return ScribeTheme.success }
        if item.isSkipped { return ScribeTheme.secondaryText.opacity(0.15) }
        return categoryTint.opacity(0.18)
    }

    private var avatarForeground: Color {
        if item.isConfirmed { return ScribeTheme.textOnPrimary }
        if item.isSkipped { return ScribeTheme.secondaryText }
        return categoryTint
    }

    private var confirmAccessibilityLabel: String {
        if isIncome {
            return item.isConfirmed ? "Undo received" : "Mark as received"
        }
        return item.isConfirmed ? "Undo paid" : "Mark as paid"
    }

    var body: some View {
        HStack(spacing: ScribeDesign.Spacing.m) {
            Button(action: onConfirm) {
                ZStack {
                    Circle()
                        .fill(avatarFill)
                        .frame(width: 40, height: 40)
                    Image(systemName: avatarIcon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(avatarForeground)
                }
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(confirmAccessibilityLabel)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.budgetItem.name)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(ScribeTheme.primaryText)
                    .strikethrough(item.isConfirmed || item.isSkipped)
                    .lineLimit(1)

                Text(item.dueDate, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day())
                    .font(.caption)
                    .foregroundStyle(isOverdue ? .orange : ScribeTheme.secondaryText)
            }

            Spacer(minLength: ScribeDesign.Spacing.s)

            amountDisplay
        }
        .opacity(item.isSkipped ? 0.55 : 1)
        .contentShape(Rectangle())
        .onTapGesture { onTap?() }
        .contextMenu {
            if item.isConfirmed {
                Button {
                    editAmountText = "\(displayAmount)"
                    showingAmountEditor = true
                } label: {
                    Label("Edit Amount", systemImage: "pencil")
                }
            }

            Button {
                onConfirm()
            } label: {
                if item.isConfirmed {
                    Label(isIncome ? "Undo Received" : "Undo Paid", systemImage: "arrow.uturn.backward")
                } else {
                    Label(isIncome ? "Mark as Received" : "Mark as Paid", systemImage: "checkmark.circle")
                }
            }

            Button {
                onSkip()
            } label: {
                Label(item.isSkipped ? "Undo Skip" : "Skip", systemImage: "arrow.uturn.right")
            }
        }
        .popover(isPresented: $showingAmountEditor) {
            amountEditorPopover
        }
    }

    private var amountDisplay: some View {
        VStack(alignment: .trailing, spacing: 2) {
            if isForeignCurrency, let converted = convertedAmount {
                HStack(spacing: 1) {
                    Text("*")
                        .foregroundStyle(ScribeTheme.secondaryText)
                    MoneyText(
                        amount: converted,
                        currencyCode: exchangeRateCache.baseCurrency,
                        type: item.budgetItem.type,
                        emphasis: .money
                    )
                }

                Text("\(item.budgetItem.currencyCode) \(CurrencyFormatter.formatNumber(displayAmount))")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(ScribeTheme.secondaryText)
            } else {
                MoneyText(
                    amount: displayAmount,
                    currencyCode: item.budgetItem.currencyCode,
                    type: item.budgetItem.type,
                    emphasis: .money
                )
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
