import SwiftUI
import SwiftData

struct BudgetSummaryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(filter: #Predicate<BudgetItem> { $0.isActive }, sort: \BudgetItem.sortOrder)
    private var budgetItems: [BudgetItem]
    @Query private var occurrences: [Occurrence]
    @Query(sort: \DashboardSection.sortOrder) private var dashboardSections: [DashboardSection]

    @State private var viewModel = DashboardViewModel()
    @State private var holidays: Set<Date> = []

    private var baseCurrency: String { ExchangeRateCache.shared.baseCurrency }

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
            await ExchangeRateCache.shared.load()
        }
    }

    // MARK: - Weekly View (matches main app)

    private func weeklyView(section: DashboardSection) -> some View {
        let groups = viewModel.weeklyGroups(
            budgetItems: budgetItems,
            occurrences: occurrences,
            anchor: section.anchor,
            range: SettingsViewModel.currentDefaultRange(),
            holidays: holidays,
            exchangeRates: ExchangeRateCache.shared.rates,
            baseCurrency: ExchangeRateCache.shared.baseCurrency,
            rollingNet: SettingsViewModel.currentRollingWeeklyNet()
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
                            .foregroundStyle(WatchTheme.secondary)
                    }
                }
            }
        }
        .navigationTitle("Scribe")
    }

    private func weekGroupHeader(_ group: DashboardViewModel.WeekGroup) -> some View {
        let net = group.rollingNet ?? group.delta
        return VStack(alignment: .leading, spacing: 5) {
            Text(group.label)
                .font(.caption2)
                .foregroundStyle(WatchTheme.secondary)

            HStack(alignment: .firstTextBaseline) {
                Text(group.rollingNet != nil ? "Net (rolling)" : "Net")
                    .font(.system(size: 10))
                    .foregroundStyle(WatchTheme.secondary)
                Spacer()
                WatchMoney(net, currencyCode: baseCurrency, sign: .automatic,
                           font: .title3.monospacedDigit().bold())
            }

            HStack {
                miniStat("In", group.totalIncome, type: .income, align: .leading)
                Spacer()
                miniStat("Out", group.totalExpenses, type: .expense, align: .trailing)
            }

            if group.totalCount > 0 {
                Text("\(group.confirmedCount)/\(group.totalCount) confirmed")
                    .font(.system(size: 9))
                    .foregroundStyle(WatchTheme.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func miniStat(_ label: String, _ amount: Decimal, type: ItemType, align: HorizontalAlignment) -> some View {
        VStack(alignment: align, spacing: 0) {
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(WatchTheme.secondary)
            WatchMoney(amount, currencyCode: baseCurrency, type: type, sign: .none)
        }
    }

    private func watchItemRow(_ item: DashboardViewModel.UpcomingItem) -> some View {
        let type = item.budgetItem.type
        let avatarTint: Color = item.isConfirmed ? WatchTheme.income
            : item.isSkipped ? WatchTheme.secondary
            : WatchTheme.categoryTint(for: type)
        let avatarIcon = item.isConfirmed ? (type == .income ? "arrow.down" : "checkmark")
            : item.isSkipped ? "arrow.uturn.right"
            : item.budgetItem.category.systemImage

        return HStack(spacing: 8) {
            WatchAvatar(systemImage: avatarIcon, tint: avatarTint, size: 24)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.budgetItem.name)
                    .font(.caption2)
                    .lineLimit(1)
                    .strikethrough(item.isConfirmed || item.isSkipped)
                Text(item.dueDate, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated))
                    .font(.system(size: 9))
                    .foregroundStyle(WatchTheme.secondary)
            }

            Spacer(minLength: 4)

            WatchMoney(
                item.effectiveBalanceAmount,
                currencyCode: item.budgetItem.currencyCode,
                type: type,
                sign: type == .income ? .alwaysPositive : .alwaysNegative
            )
        }
        .opacity(item.isSkipped ? 0.5 : 1)
    }

    // MARK: - Fallback (no weekly section configured)

    private var fallbackView: some View {
        List {
            Section {
                let summary = computeSummary()
                let net = summary.totalIncome - summary.totalExpenses
                VStack(alignment: .leading, spacing: 6) {
                    Text("Next 7 Days")
                        .font(.caption2)
                        .foregroundStyle(WatchTheme.secondary)
                    WatchMoney(net, currencyCode: baseCurrency, sign: .automatic,
                               font: .title2.monospacedDigit().bold())
                    HStack {
                        miniStat("In", summary.totalIncome, type: .income, align: .leading)
                        Spacer()
                        miniStat("Out", summary.totalExpenses, type: .expense, align: .trailing)
                    }
                }
                .padding(.vertical, 2)
            }

            Section("Upcoming") {
                let upcoming = computeUpcomingItems()
                if upcoming.isEmpty {
                    Text("No upcoming items")
                        .font(.caption2)
                        .foregroundStyle(WatchTheme.secondary)
                } else {
                    ForEach(upcoming.prefix(10)) { item in
                        HStack(spacing: 8) {
                            WatchAvatar(
                                systemImage: item.isIncome ? "dollarsign.circle" : item.systemImage,
                                tint: WatchTheme.categoryTint(for: item.isIncome ? .income : .expense),
                                size: 24
                            )
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.name)
                                    .font(.caption2)
                                    .lineLimit(1)
                                Text(item.dueDate, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day())
                                    .font(.system(size: 9))
                                    .foregroundStyle(WatchTheme.secondary)
                            }
                            Spacer(minLength: 4)
                            WatchMoney(
                                item.amount,
                                currencyCode: item.currencyCode,
                                type: item.isIncome ? .income : .expense,
                                sign: item.isIncome ? .alwaysPositive : .alwaysNegative
                            )
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
        let systemImage: String
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
                    dueDate: date,
                    systemImage: item.category.systemImage
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
