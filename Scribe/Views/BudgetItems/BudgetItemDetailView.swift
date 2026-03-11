import SwiftUI
import SwiftData

struct BudgetItemDetailView: View {
    @Environment(\.modelContext) private var modelContext
    let item: BudgetItem
    @State private var showingEditSheet = false
    @State private var showingOverrideSheet = false

    var body: some View {
        List {
            Section("Details") {
                LabeledContent("Type", value: item.type.displayName)
                LabeledContent("Amount") {
                    AmountText(
                        amount: item.amount,
                        currencyCode: item.currencyCode,
                        type: item.type
                    )
                }
                LabeledContent("Currency", value: item.currencyCode)
                LabeledContent("Frequency", value: item.frequency.displayName)
                if item.frequency == .monthly, let day = item.dayOfMonth {
                    LabeledContent("Day of Month", value: "\(day)")
                }
                if item.frequency.usesReferenceDate, let date = item.referenceDate {
                    LabeledContent("Reference Date") {
                        Text(date, format: .dateTime.day().month().year())
                    }
                }
                LabeledContent("Category", value: item.category.displayName)
                LabeledContent("Active", value: item.isActive ? "Yes" : "No")
                if let notes = item.notes, !notes.isEmpty {
                    LabeledContent("Notes", value: notes)
                }
            }

            if item.type == .income {
                Section("Income Settings") {
                    LabeledContent("Budget Reflection", value: item.budgetReflection.displayName)
                    if !item.payDayAdjustmentWeekdays.isEmpty {
                        let weekdayNames = [(1, "Sun"), (2, "Mon"), (3, "Tue"), (4, "Wed"), (5, "Thu"), (6, "Fri"), (7, "Sat")]
                        let adjustmentNames = weekdayNames
                            .filter { item.payDayAdjustmentWeekdays.contains($0.0) }
                            .map(\.1)
                            .joined(separator: ", ")
                        LabeledContent("Pay Day Adjustments", value: adjustmentNames)
                    } else {
                        LabeledContent("Pay Day Adjustments", value: "None")
                    }
                    if let code = item.publicHolidayCountryCode {
                        let countryName = Locale.current.localizedString(forRegionCode: code) ?? code
                        LabeledContent("Holiday Country", value: "\(countryName) (\(code))")
                    } else {
                        LabeledContent("Holiday Country", value: "None")
                    }
                    LabeledContent("Show Last in Day", value: item.showLast ? "Yes" : "No")
                }
            }

            Section("Amount History") {
                if item.amountOverrides.isEmpty {
                    Text("No amount changes recorded")
                        .foregroundStyle(ScribeTheme.secondaryText)
                } else {
                    let sorted = item.amountOverrides.sorted { $0.effectiveDate > $1.effectiveDate }
                    ForEach(sorted) { override_ in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(override_.effectiveDate, format: .dateTime.day().month().year())
                                    .font(.subheadline)
                                if let notes = override_.notes {
                                    Text(notes)
                                        .font(.caption)
                                        .foregroundStyle(ScribeTheme.secondaryText)
                                }
                            }
                            Spacer()
                            AmountText(
                                amount: override_.amount,
                                currencyCode: item.currencyCode,
                                type: item.type
                            )
                        }
                    }
                }

                Button {
                    showingOverrideSheet = true
                } label: {
                    Label("Add Amount Change", systemImage: "plus.circle")
                }
            }

            Section("Upcoming Occurrences") {
                let calendar = Calendar.current
                let today = calendar.startOfDay(for: Date())
                if let endDate = calendar.date(byAdding: .month, value: 3, to: today) {
                    let dates = DateCalculator.occurrenceDates(for: item, in: today...endDate)
                    ForEach(dates.prefix(10), id: \.self) { date in
                        HStack {
                            Text(date, format: .dateTime.weekday(.abbreviated).day().month())
                            Spacer()
                            AmountText(
                                amount: item.effectiveAmount(on: date),
                                currencyCode: item.currencyCode,
                                type: item.type
                            )
                            .font(.body.monospacedDigit())
                        }
                    }
                }
            }
        }
        .navigationTitle(item.name)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Edit") {
                    showingEditSheet = true
                }
            }
        }
        .sheet(isPresented: $showingEditSheet) {
            BudgetItemFormView(mode: .edit(item))
        }
        .sheet(isPresented: $showingOverrideSheet) {
            AddOverrideSheet(item: item)
        }
    }
}

private struct AddOverrideSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    let item: BudgetItem

    @State private var amount: String = ""
    @State private var effectiveDate: Date = Date()
    @State private var changeDayOfMonth: Bool = false
    @State private var newDayOfMonth: Int = 1
    @State private var notes: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Effective Date") {
                    DatePicker("From", selection: $effectiveDate, displayedComponents: .date)
                }

                Section("New Amount") {
                    TextField("Amount", text: $amount)
                        .keyboardType(.decimalPad)
                }

                if item.frequency == .monthly {
                    Section("Schedule Change") {
                        Toggle("Change Day of Month", isOn: $changeDayOfMonth)
                        if changeDayOfMonth {
                            Stepper("Day: \(newDayOfMonth)", value: $newDayOfMonth, in: 1...31)
                        }
                    }
                }

                Section {
                    TextField("Notes (optional)", text: $notes)
                }
            }
            .navigationTitle("Change Going Forward")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if let decimalAmount = Decimal(string: amount) {
                            let override_ = AmountOverride(
                                effectiveDate: effectiveDate,
                                amount: decimalAmount,
                                overrideDayOfMonth: changeDayOfMonth ? newDayOfMonth : nil,
                                notes: notes.isEmpty ? nil : notes,
                                budgetItem: item
                            )
                            modelContext.insert(override_)
                            try? modelContext.save()
                            SyncCoordinator.shared.pushChange(for: override_.id)
                            dismiss()
                        }
                    }
                    .disabled(Decimal(string: amount) == nil)
                }
            }
            .onAppear {
                amount = "\(item.amount)"
                newDayOfMonth = item.dayOfMonth ?? 1
            }
        }
    }
}
