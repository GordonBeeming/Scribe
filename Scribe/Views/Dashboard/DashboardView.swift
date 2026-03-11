import SwiftUI
import SwiftData

struct DashboardView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(filter: #Predicate<BudgetItem> { $0.isActive }) private var activeItems: [BudgetItem]
    @Query private var allItems: [BudgetItem]
    @Query private var occurrences: [Occurrence]
    @Query(sort: \DashboardSection.sortOrder) private var dashboardSections: [DashboardSection]
    @Query(sort: \QuickAdjustment.date) private var quickAdjustments: [QuickAdjustment]

    @State private var viewModel = DashboardViewModel()
    @State private var selectedItem: BudgetItem?
    @State private var irregularConfirmItem: DashboardViewModel.UpcomingItem?
    @State private var holidays: Set<Date> = []

    private func adjustAmount(_ item: DashboardViewModel.UpcomingItem, newAmount: Decimal) {
        guard let occurrence = item.occurrence else { return }
        occurrence.actualAmount = newAmount
        try? modelContext.save()
        SyncCoordinator.shared.pushChange(for: occurrence.id)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                if allItems.isEmpty {
                    emptyState
                } else {
                    let enabledSections = dashboardSections.filter(\.isEnabled)
                    if enabledSections.isEmpty {
                        VStack(spacing: 16) {
                            PeriodSummaryCard(
                                budgetItems: activeItems,
                                occurrences: occurrences
                            )

                            UpcomingExpensesCard(
                                items: viewModel.upcomingItems(
                                    budgetItems: activeItems,
                                    occurrences: occurrences
                                ),
                                onConfirm: confirmOccurrence,
                                onSkip: skipOccurrence,
                                onTap: { selectedItem = $0.budgetItem },
                                onAdjustAmount: adjustAmount
                            )
                        }
                        .padding()
                    } else {
                        VStack(spacing: 16) {
                            ForEach(enabledSections) { section in
                                switch section.sectionType {
                                case .monthlySummary:
                                    MonthlySummaryCard(
                                        summary: viewModel.monthlySummary(
                                            budgetItems: activeItems,
                                            occurrences: occurrences,
                                            anchor: section.anchor,
                                            holidays: holidays
                                        )
                                    )
                                case .detailedWeekly:
                                    let groups = viewModel.weeklyGroups(
                                        budgetItems: activeItems,
                                        occurrences: occurrences,
                                        quickAdjustments: quickAdjustments,
                                        anchor: section.anchor,
                                        range: SettingsViewModel.currentDefaultRange(),
                                        holidays: holidays
                                    )
                                    VStack(spacing: 12) {
                                        Text(section.label)
                                            .font(.title3.bold())
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                        ForEach(groups) { group in
                                            let calendar = Calendar.current
                                            let today = calendar.startOfDay(for: Date())
                                            let isCurrent = group.startDate <= today && group.endDate >= today
                                            WeeklyBudgetCard(
                                                group: group,
                                                onConfirm: confirmOccurrence,
                                                onSkip: skipOccurrence,
                                                onTap: { selectedItem = $0.budgetItem },
                                                onAdjustAmount: adjustAmount,
                                                isCurrentWeek: isCurrent
                                            )
                                        }
                                    }
                                }
                            }
                        }
                        .padding()
                    }
                }
            }
            .task {
                await loadHolidays()
                await ExchangeRateCache.shared.load()
            }
            .navigationTitle("Scribe")
            .sheet(item: $selectedItem) { item in
                NavigationStack {
                    BudgetItemDetailView(item: item)
                }
            }
            .sheet(item: $irregularConfirmItem) { upcomingItem in
                NextDatePickerSheet(itemName: upcomingItem.budgetItem.name) { nextDate in
                    scheduleNextIrregular(upcomingItem, nextDate: nextDate)
                }
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Welcome to Scribe", systemImage: "dollarsign.circle")
        } description: {
            Text("Start by adding your recurring income and expenses in the Items tab. Your budget overview will appear here.")
        } actions: {
            // No action - guide them to the Items tab
        }
        .padding(.top, 60)
    }

    private func confirmOccurrence(_ item: DashboardViewModel.UpcomingItem) {
        if let existing = item.occurrence, existing.status == .confirmed {
            existing.status = .pending
            existing.confirmedAt = nil
            existing.actualAmount = nil
            try? modelContext.save()
            SyncCoordinator.shared.pushChange(for: existing.id)
        } else {
            if item.budgetItem.frequency == .irregular {
                irregularConfirmItem = item
                return
            }
            doConfirmOccurrence(item)
        }
    }

    private func doConfirmOccurrence(_ item: DashboardViewModel.UpcomingItem) {
        if let existing = item.occurrence {
            existing.status = .confirmed
            existing.confirmedAt = Date()
            try? modelContext.save()
            SyncCoordinator.shared.pushChange(for: existing.id)
        } else {
            let occurrence = Occurrence(
                dueDate: item.dueDate,
                expectedAmount: item.amount,
                status: .confirmed,
                confirmedAt: Date(),
                budgetItem: item.budgetItem
            )
            modelContext.insert(occurrence)
            try? modelContext.save()
            SyncCoordinator.shared.pushChange(for: occurrence.id)
        }
    }

    private func scheduleNextIrregular(_ item: DashboardViewModel.UpcomingItem, nextDate: Date) {
        doConfirmOccurrence(item)

        item.budgetItem.referenceDate = nextDate
        item.budgetItem.modifiedAt = Date()
        try? modelContext.save()
        SyncCoordinator.shared.pushChange(for: item.budgetItem.id)
    }

    private func loadHolidays() async {
        let countryCodes = Set(activeItems.compactMap(\.publicHolidayCountryCode))
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

    private func skipOccurrence(_ item: DashboardViewModel.UpcomingItem) {
        if let existing = item.occurrence, existing.status == .skipped {
            existing.status = .pending
            try? modelContext.save()
            SyncCoordinator.shared.pushChange(for: existing.id)
        } else if let existing = item.occurrence {
            existing.status = .skipped
            try? modelContext.save()
            SyncCoordinator.shared.pushChange(for: existing.id)
        } else {
            let occurrence = Occurrence(
                dueDate: item.dueDate,
                expectedAmount: item.amount,
                status: .skipped,
                budgetItem: item.budgetItem
            )
            modelContext.insert(occurrence)
            try? modelContext.save()
            SyncCoordinator.shared.pushChange(for: occurrence.id)
        }
    }
}

#Preview {
    DashboardView()
        .modelContainer(for: [
            BudgetItem.self,
            AmountOverride.self,
            Occurrence.self,
            FamilyMember.self,
            DashboardSection.self,
            QuickAdjustment.self,
        ], inMemory: true)
}
