import SwiftUI
import SwiftData

struct QuickAddView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \QuickAdjustment.date, order: .reverse) private var adjustments: [QuickAdjustment]

    @State private var showingAddSheet = false
    @State private var showingBalanceSheet = false
    @State private var hasEverResetBalance = false

    private let hasResetKey = "hasEverResetBalance"

    var body: some View {
        NavigationStack {
            List {
                if !hasEverResetBalance && adjustments.allSatisfy({ $0.adjustmentType != .balanceReset }) {
                    Section {
                        Label {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Set your starting balance")
                                    .font(.subheadline.bold())
                                Text("Tap \"Adjust Balance\" to set your current real account balance. Weekly budgets will track from this point.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "lightbulb.fill")
                                .foregroundStyle(.yellow)
                        }
                    }
                }

                if adjustments.isEmpty {
                    ContentUnavailableView(
                        "No Adjustments Yet",
                        systemImage: "bolt.circle",
                        description: Text("Add one-off expenses, income, or adjust your balance.")
                    )
                } else {
                    // Group by month
                    let grouped = Dictionary(grouping: adjustments) { adj -> String in
                        adj.date.formatted(.dateTime.month(.wide).year())
                    }
                    let sortedKeys = grouped.keys.sorted { k1, k2 in
                        (grouped[k1]?.first?.date ?? .distantPast) > (grouped[k2]?.first?.date ?? .distantPast)
                    }

                    ForEach(sortedKeys, id: \.self) { key in
                        Section(key) {
                            ForEach(grouped[key] ?? []) { adjustment in
                                adjustmentRow(adjustment)
                            }
                            .onDelete { offsets in
                                deleteAdjustments(in: grouped[key] ?? [], at: offsets)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Quick Add")
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        showingBalanceSheet = true
                    } label: {
                        Label("Adjust Balance", systemImage: "arrow.triangle.2.circlepath")
                    }

                    Button {
                        showingAddSheet = true
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingAddSheet) {
                QuickAddFormSheet(mode: .expenseOrIncome)
            }
            .sheet(isPresented: $showingBalanceSheet) {
                QuickAddFormSheet(mode: .balanceReset)
            }
            .onAppear {
                hasEverResetBalance = UserDefaults.standard.bool(forKey: hasResetKey)
            }
        }
    }

    private func adjustmentRow(_ adjustment: QuickAdjustment) -> some View {
        HStack(spacing: 10) {
            Image(systemName: adjustment.adjustmentType.systemImage)
                .foregroundStyle(adjustmentColor(adjustment))
                .frame(width: 24)

            VStack(alignment: .leading) {
                Text(adjustment.name)
                    .font(.subheadline)
                Text(adjustment.date, format: .dateTime.weekday(.abbreviated).day().month().year())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let notes = adjustment.notes, !notes.isEmpty {
                    Text(notes)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if adjustment.adjustmentType == .balanceReset {
                Text(CurrencyFormatter.format(adjustment.amount, currencyCode: adjustment.currencyCode, signStyle: .none))
                    .font(.subheadline.monospacedDigit().bold())
                    .foregroundStyle(.primary)
            } else {
                Text(CurrencyFormatter.format(
                    adjustment.amount,
                    currencyCode: adjustment.currencyCode,
                    signStyle: adjustment.adjustmentType == .income ? .alwaysPositive : .alwaysNegative
                ))
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(adjustmentColor(adjustment))
            }
        }
    }

    private func adjustmentColor(_ adjustment: QuickAdjustment) -> Color {
        switch adjustment.adjustmentType {
        case .income: ScribeTheme.success
        case .expense: ScribeTheme.error
        case .balanceReset: .primary
        }
    }

    private func deleteAdjustments(in list: [QuickAdjustment], at offsets: IndexSet) {
        for index in offsets {
            let adjustment = list[index]
            SyncCoordinator.shared.pushDeletion(for: adjustment.id)
            modelContext.delete(adjustment)
        }
        try? modelContext.save()
    }
}

// MARK: - Quick Add Form Sheet

struct QuickAddFormSheet: View {
    enum Mode {
        case expenseOrIncome
        case balanceReset
    }

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let mode: Mode

    @State private var adjustmentType: QuickAdjustmentType = .expense
    @State private var amountText = ""
    @State private var name = ""
    @State private var date = Date()
    @State private var notes = ""
    @State private var currencyCode = "AUD"

    private var isValid: Bool {
        guard let amount = Decimal(string: amountText), amount > 0 else { return false }
        if mode == .expenseOrIncome {
            return !name.trimmingCharacters(in: .whitespaces).isEmpty
        }
        return true
    }

    var body: some View {
        NavigationStack {
            Form {
                if mode == .expenseOrIncome {
                    Section {
                        Picker("Type", selection: $adjustmentType) {
                            Text("Expense").tag(QuickAdjustmentType.expense)
                            Text("Income").tag(QuickAdjustmentType.income)
                        }
                        .pickerStyle(.segmented)
                    }

                    Section("Details") {
                        TextField("Name", text: $name)
                        HStack {
                            Text(currencySymbol)
                            TextField("Amount", text: $amountText)
                                .keyboardType(.decimalPad)
                        }
                        DatePicker("Date", selection: $date, displayedComponents: .date)
                    }
                } else {
                    Section {
                        Text("Set the actual balance in your account right now. Weekly budgets will recalculate from this point.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Section("Balance") {
                        HStack {
                            Text(currencySymbol)
                            TextField("Current Balance", text: $amountText)
                                .keyboardType(.decimalPad)
                        }
                        DatePicker("As of", selection: $date, displayedComponents: .date)
                    }
                }

                Section("Notes") {
                    TextField("Notes (optional)", text: $notes, axis: .vertical)
                        .lineLimit(2...4)
                }
            }
            .navigationTitle(mode == .balanceReset ? "Adjust Balance" : "Quick Add")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save()
                        dismiss()
                    }
                    .disabled(!isValid)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private var currencySymbol: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currencyCode
        return formatter.currencySymbol ?? "$"
    }

    private func save() {
        guard let amount = Decimal(string: amountText) else { return }

        let type: QuickAdjustmentType = mode == .balanceReset ? .balanceReset : adjustmentType
        let adjustmentName: String
        if mode == .balanceReset {
            adjustmentName = "Balance Adjustment"
        } else {
            adjustmentName = name.trimmingCharacters(in: .whitespaces)
        }

        let adjustment = QuickAdjustment(
            type: type,
            date: date,
            amount: amount,
            name: adjustmentName,
            currencyCode: currencyCode,
            notes: notes.isEmpty ? nil : notes
        )

        modelContext.insert(adjustment)
        try? modelContext.save()
        SyncCoordinator.shared.pushChange(for: adjustment.id)

        if type == .balanceReset {
            UserDefaults.standard.set(true, forKey: "hasEverResetBalance")
        }
    }
}
