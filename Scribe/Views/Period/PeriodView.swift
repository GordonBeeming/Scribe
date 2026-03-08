import SwiftUI
import SwiftData

struct PeriodView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Query(filter: #Predicate<BudgetItem> { $0.isActive }) private var activeItems: [BudgetItem]
    @Query private var occurrences: [Occurrence]

    @State private var viewModel = PeriodViewModel()
    @State private var showingDatePicker = false

    private var days: [PeriodViewModel.DayData] {
        viewModel.generateDays(budgetItems: activeItems, occurrences: occurrences)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                dateRangeHeader

                if activeItems.isEmpty {
                    ContentUnavailableView(
                        "No Active Items",
                        systemImage: "calendar.badge.exclamationmark",
                        description: Text("Add budget items in the Items tab to see them here.")
                    )
                } else if days.isEmpty {
                    ContentUnavailableView(
                        "No Items in Range",
                        systemImage: "calendar",
                        description: Text("No items are due in the selected date range. Try a wider range.")
                    )
                } else if horizontalSizeClass == .regular {
                    iPadGridView
                } else {
                    iPhoneListView
                }
            }
            .navigationTitle("Period")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingDatePicker = true
                    } label: {
                        Image(systemName: "calendar.badge.clock")
                    }
                }

                ToolbarItem(placement: .topBarLeading) {
                    dateRangeLabel
                }
            }
            .sheet(isPresented: $showingDatePicker) {
                DateRangePickerSheet(
                    startDate: $viewModel.startDate,
                    endDate: $viewModel.endDate,
                    onQuickRange: { viewModel.setQuickRange($0) }
                )
            }
        }
    }

    private var dateRangeLabel: some View {
        Text("\(viewModel.startDate, format: .dateTime.day().month()) - \(viewModel.endDate, format: .dateTime.day().month())")
            .font(.caption)
            .foregroundStyle(ScribeTheme.secondaryText)
    }

    private var dateRangeHeader: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(PeriodViewModel.QuickRange.allCases) { range in
                    Button(range.rawValue) {
                        viewModel.setQuickRange(range)
                    }
                    .font(.subheadline)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .glassEffect(.regular.interactive(), in: .capsule)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
    }

    // MARK: - iPhone Layout

    private var iPhoneListView: some View {
        List {
            let allDays = days
            var runningTotal: Decimal = 0

            ForEach(allDays) { day in
                let _ = { runningTotal += day.dayTotal }()
                Section {
                    ForEach(day.items) { item in
                        OccurrenceRowView(
                            item: item,
                            onConfirm: { confirmItem(item, on: day.date) },
                            onSkip: { skipItem(item, on: day.date) }
                        )
                    }
                } header: {
                    PeriodDayColumn(date: day.date, dayTotal: day.dayTotal, runningTotal: runningTotal)
                }
            }

            // Period summary at the bottom
            Section {
                periodSummaryRow
            }
        }
        .listStyle(.plain)
    }

    private var periodSummaryRow: some View {
        let allDays = days
        let totalIncome = allDays.flatMap(\.items).filter { $0.budgetItem.type == .income }.reduce(Decimal.zero) { $0 + $1.amount }
        let totalExpenses = allDays.flatMap(\.items).filter { $0.budgetItem.type == .expense }.reduce(Decimal.zero) { $0 + $1.amount }
        let net = totalIncome - totalExpenses

        return VStack(spacing: 8) {
            HStack {
                Text("Total Income")
                Spacer()
                AmountText(amount: totalIncome, currencyCode: "AUD", type: .income, showSign: false)
            }
            .font(.subheadline)
            HStack {
                Text("Total Expenses")
                Spacer()
                AmountText(amount: totalExpenses, currencyCode: "AUD", type: .expense, showSign: false)
            }
            .font(.subheadline)
            Divider()
            HStack {
                Text("Net")
                    .font(.headline)
                Spacer()
                AmountText(amount: net, currencyCode: "AUD", showSign: true)
                    .font(.headline.monospacedDigit())
            }
        }
    }

    // MARK: - iPad Layout

    private var iPadGridView: some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: 1) {
                ForEach(days) { day in
                    VStack(alignment: .leading, spacing: 8) {
                        PeriodDayColumn(date: day.date, dayTotal: day.dayTotal, runningTotal: nil)
                            .padding(.bottom, 4)

                        ForEach(day.items) { item in
                            OccurrenceRowView(
                                item: item,
                                onConfirm: { confirmItem(item, on: day.date) },
                                onSkip: { skipItem(item, on: day.date) }
                            )
                        }

                        Spacer()
                    }
                    .frame(width: 200)
                    .padding()
                    .glassEffect(.regular, in: .rect(cornerRadius: 12))
                }
            }
            .padding()
        }
    }

    // MARK: - Actions

    private func confirmItem(_ item: PeriodViewModel.DayItem, on date: Date) {
        if let existing = item.occurrence {
            existing.status = .confirmed
            existing.confirmedAt = Date()
        } else {
            let occurrence = Occurrence(
                dueDate: date,
                expectedAmount: item.amount,
                status: .confirmed,
                confirmedAt: Date(),
                budgetItem: item.budgetItem
            )
            modelContext.insert(occurrence)
        }
        try? modelContext.save()
    }

    private func skipItem(_ item: PeriodViewModel.DayItem, on date: Date) {
        if let existing = item.occurrence {
            existing.status = .skipped
        } else {
            let occurrence = Occurrence(
                dueDate: date,
                expectedAmount: item.amount,
                status: .skipped,
                budgetItem: item.budgetItem
            )
            modelContext.insert(occurrence)
        }
        try? modelContext.save()
    }
}

// MARK: - Date Range Picker Sheet

private struct DateRangePickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var startDate: Date
    @Binding var endDate: Date
    let onQuickRange: (PeriodViewModel.QuickRange) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Quick Ranges") {
                    ForEach(PeriodViewModel.QuickRange.allCases) { range in
                        Button(range.rawValue) {
                            onQuickRange(range)
                            dismiss()
                        }
                    }
                }

                Section("Custom Range") {
                    DatePicker("Start", selection: $startDate, displayedComponents: .date)
                    DatePicker("End", selection: $endDate, displayedComponents: .date)
                }
            }
            .navigationTitle("Date Range")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

#Preview {
    PeriodView()
        .modelContainer(for: [
            BudgetItem.self,
            AmountOverride.self,
            Occurrence.self,
            FamilyMember.self,
        ], inMemory: true)
}
