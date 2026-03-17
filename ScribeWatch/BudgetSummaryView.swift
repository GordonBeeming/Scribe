import SwiftUI
import SwiftData

struct BudgetSummaryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(filter: #Predicate<BudgetItem> { $0.isActive }, sort: \BudgetItem.sortOrder)
    private var budgetItems: [BudgetItem]
    @Query private var occurrences: [Occurrence]
    @Query(sort: \DashboardSection.sortOrder) private var dashboardSections: [DashboardSection]
    @Query(sort: \QuickAdjustment.date) private var quickAdjustments: [QuickAdjustment]

    @State private var viewModel = DashboardViewModel()
    @State private var holidays: Set<Date> = []

    var body: some View {
        NavigationStack {
            let enabledSections = dashboardSections.filter(\.isEnabled)
            let weeklySection = enabledSections.first { $0.sectionType == .detailedWeekly }

            if let section = weeklySection {
                weeklyView(section: section)
            } else {
                fallbackView
            }
        }
        .task {
            await loadHolidays()
        }
    }

    // MARK: - Weekly View (matches main app)

    private func weeklyView(section: DashboardSection) -> some View {
        let groups = viewModel.weeklyGroups(
            budgetItems: budgetItems,
            occurrences: occurrences,
            quickAdjustments: quickAdjustments,
            anchor: section.anchor,
            range: SettingsViewModel.currentDefaultRange(),
            holidays: holidays
        )

        return List {
            ForEach(groups) { group in
                Section {
                    weekGroupHeader(group)
                    ForEach(group.items.prefix(10)) { item in
                        watchItemRow(item)
                    }
                    if group.items.count > 10 {
                        Text("+\(group.items.count - 10) more")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Scribe")
    }

    private func weekGroupHeader(_ group: DashboardViewModel.WeekGroup) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(group.label)
                .font(.caption2)
                .foregroundStyle(.secondary)

            HStack {
                VStack(alignment: .leading) {
                    Text("Opening")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                    Text(CurrencyFormatter.format(group.carryOver, currencyCode: "AUD", signStyle: .automatic))
                        .font(.caption2.monospacedDigit())
                }

                Spacer()

                VStack(alignment: .trailing) {
                    Text("Closing")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                    Text(CurrencyFormatter.format(group.closingBalance, currencyCode: "AUD", signStyle: .automatic))
                        .font(.headline.monospacedDigit().bold())
                        .foregroundStyle(group.closingBalance >= 0 ? .green : .red)
                }
            }

            if group.totalCount > 0 {
                Text("\(group.confirmedCount)/\(group.totalCount) confirmed")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func watchItemRow(_ item: DashboardViewModel.UpcomingItem) -> some View {
        HStack {
            Image(systemName: item.isConfirmed ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(item.isConfirmed ? .green : .secondary)
                .font(.caption2)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.budgetItem.name)
                    .font(.caption2)
                    .lineLimit(1)
                    .strikethrough(item.isConfirmed)
                Text(item.dueDate, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated))
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(CurrencyFormatter.format(
                item.effectiveBalanceAmount,
                currencyCode: item.budgetItem.currencyCode,
                signStyle: item.budgetItem.type == .income ? .alwaysPositive : .alwaysNegative
            ))
            .font(.caption2.monospacedDigit())
            .foregroundStyle(item.budgetItem.type == .income ? .green : .red)
        }
    }

    // MARK: - Fallback (no weekly section configured)

    private var fallbackView: some View {
        List {
            Section {
                let summary = computeSummary()
                VStack(alignment: .leading, spacing: 4) {
                    Text("Next 7 Days")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        let net = summary.totalIncome - summary.totalExpenses
                        Text(CurrencyFormatter.format(net, currencyCode: "AUD", signStyle: .automatic))
                            .font(.title3.monospacedDigit().bold())
                            .foregroundStyle(net >= 0 ? .green : .red)
                    }
                    HStack(spacing: 12) {
                        Label(CurrencyFormatter.format(summary.totalIncome, currencyCode: "AUD", signStyle: .none),
                              systemImage: "arrow.down.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(.green)
                        Label(CurrencyFormatter.format(summary.totalExpenses, currencyCode: "AUD", signStyle: .none),
                              systemImage: "arrow.up.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(.red)
                    }
                }
                .padding(.vertical, 2)
            }

            Section("Upcoming") {
                let upcoming = computeUpcomingItems()
                if upcoming.isEmpty {
                    Text("No upcoming items")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(upcoming.prefix(10), id: \.id) { item in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.name)
                                    .font(.caption)
                                    .lineLimit(1)
                                Text(item.dueDate, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day())
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(CurrencyFormatter.format(item.amount, currencyCode: item.currencyCode,
                                signStyle: item.isIncome ? .alwaysPositive : .alwaysNegative))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(item.isIncome ? .green : .red)
                        }
                    }
                }
            }
        }
        .navigationTitle("Scribe")
        #if DEBUG
        .toolbar {
            if budgetItems.isEmpty {
                ToolbarItem(placement: .bottomBar) {
                    Button("Load Demo Data") {
                        DataManagementService.clearAllData(in: modelContext)
                        DemoDataGenerator.generate(in: modelContext)
                    }
                }
            }
        }
        #endif
    }

    // MARK: - Fallback Helpers

    private struct Summary {
        let totalIncome: Decimal
        let totalExpenses: Decimal
    }

    private struct SimpleUpcomingItem: Identifiable {
        let id = UUID()
        let name: String
        let amount: Decimal
        let currencyCode: String
        let isIncome: Bool
        let dueDate: Date
    }

    private func computeSummary() -> Summary {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        guard let endDate = calendar.date(byAdding: .day, value: 7, to: today) else {
            return Summary(totalIncome: 0, totalExpenses: 0)
        }

        var totalIncome: Decimal = 0
        var totalExpenses: Decimal = 0

        for item in budgetItems {
            let dates = DateCalculator.occurrenceDates(for: item, in: today...endDate)
            for date in dates {
                let amount = item.effectiveAmount(on: date)
                if item.type == .income {
                    totalIncome += amount
                } else {
                    totalExpenses += amount
                }
            }
        }

        return Summary(totalIncome: totalIncome, totalExpenses: totalExpenses)
    }

    private func computeUpcomingItems() -> [SimpleUpcomingItem] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        guard let endDate = calendar.date(byAdding: .day, value: 7, to: today) else { return [] }

        var items: [SimpleUpcomingItem] = []
        for item in budgetItems {
            let dates = DateCalculator.occurrenceDates(for: item, in: today...endDate)
            for date in dates {
                items.append(SimpleUpcomingItem(
                    name: item.name,
                    amount: item.effectiveAmount(on: date),
                    currencyCode: item.currencyCode,
                    isIncome: item.type == .income,
                    dueDate: date
                ))
            }
        }
        items.sort { $0.dueDate < $1.dueDate }
        return items
    }

    private func loadHolidays() async {
        let countryCodes = Set(budgetItems.compactMap(\.publicHolidayCountryCode))
        guard !countryCodes.isEmpty else { return }
        let calendar = Calendar.current
        let year = calendar.component(.year, from: Date())
        var allHolidays: Set<Date> = []
        for code in countryCodes {
            let dates = await HolidayService.shared.holidayDates(for: code, year: year)
            allHolidays.formUnion(dates)
            let nextDates = await HolidayService.shared.holidayDates(for: code, year: year + 1)
            allHolidays.formUnion(nextDates)
        }
        holidays = allHolidays
    }
}
