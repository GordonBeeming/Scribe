import SwiftUI
import SwiftData
import os

private let dashboardLogger = Logger(subsystem: "com.gordonbeeming.scribe", category: "DashboardView")

struct DashboardView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(filter: #Predicate<BudgetItem> { $0.isActive }) private var activeItems: [BudgetItem]
    @Query private var allItems: [BudgetItem]
    @Query private var occurrences: [Occurrence]
    @Query(sort: \DashboardSection.sortOrder) private var dashboardSections: [DashboardSection]

    @State private var viewModel = DashboardViewModel()
    @State private var selectedItem: BudgetItem?
    @State private var irregularConfirmItem: DashboardViewModel.UpcomingItem?
    @State private var holidays: Set<Date> = []

    private var lookbackDays: Int {
        SettingsViewModel.currentLookbackDays()
    }

    private func adjustAmount(_ item: DashboardViewModel.UpcomingItem, newAmount: Decimal) {
        guard let occurrence = item.occurrence else { return }
        let id = OccurrenceMatching.adjustAmount(occurrence: occurrence, newAmount: newAmount, in: modelContext)
        SyncCoordinator.shared.pushChange(for: id)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                Group {
                    if allItems.isEmpty {
                        emptyState
                    } else {
                        dashboardContent
                    }
                }
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
                .padding()
            }
            .scribeScreen()
            .task {
                dashboardLogger.info("DashboardView appeared: \(dashboardSections.count) sections, \(dashboardSections.filter(\.isEnabled).count) enabled")
                await loadHolidays()
                await ExchangeRateCache.shared.load()
                autoConfirmOldItems()
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

    @ViewBuilder
    private var dashboardContent: some View {
        let enabledSections = dashboardSections.filter(\.isEnabled)
        GlassEffectContainer(spacing: ScribeDesign.Spacing.l) {
            if enabledSections.isEmpty {
                VStack(spacing: ScribeDesign.Spacing.l) {
                    PeriodSummaryCard(
                        budgetItems: activeItems,
                        occurrences: occurrences
                    )
                    UpcomingExpensesCard(
                        items: viewModel.upcomingItems(
                            budgetItems: activeItems,
                            occurrences: occurrences,
                            lookbackDays: lookbackDays
                        ),
                        onConfirm: confirmOccurrence,
                        onSkip: skipOccurrence,
                        onTap: { selectedItem = $0.budgetItem },
                        onAdjustAmount: adjustAmount
                    )
                }
            } else {
                VStack(spacing: ScribeDesign.Spacing.xxl) {
                    ForEach(enabledSections) { section in
                        sectionView(section)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func sectionView(_ section: DashboardSection) -> some View {
        switch section.sectionType {
        case .monthlySummary:
            MonthlySummaryCard(
                summary: viewModel.monthlySummary(
                    budgetItems: activeItems,
                    occurrences: occurrences,
                    anchor: section.anchor,
                    holidays: holidays,
                    exchangeRates: ExchangeRateCache.shared.rates,
                    baseCurrency: ExchangeRateCache.shared.baseCurrency
                )
            )
        case .detailedWeekly:
            let groups = viewModel.weeklyGroups(
                budgetItems: activeItems,
                occurrences: occurrences,
                anchor: section.anchor,
                range: SettingsViewModel.currentDefaultRange(),
                holidays: holidays,
                exchangeRates: ExchangeRateCache.shared.rates,
                baseCurrency: ExchangeRateCache.shared.baseCurrency,
                rollingNet: SettingsViewModel.currentRollingWeeklyNet()
            )
            let calendar = Calendar.current
            let today = calendar.startOfDay(for: Date())
            VStack(alignment: .leading, spacing: ScribeDesign.Spacing.m) {
                ScribeSectionHeader(section.label, systemImage: "calendar.day.timeline.left")
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 340), spacing: ScribeDesign.Spacing.l)],
                    alignment: .leading,
                    spacing: ScribeDesign.Spacing.l
                ) {
                    ForEach(groups) { group in
                        WeeklyBudgetCard(
                            group: group,
                            onConfirm: confirmOccurrence,
                            onSkip: skipOccurrence,
                            onTap: { selectedItem = $0.budgetItem },
                            onAdjustAmount: adjustAmount,
                            isCurrentWeek: group.startDate <= today && group.endDate >= today
                        )
                    }
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
            let id = OccurrenceMatching.undoConfirm(occurrence: existing, in: modelContext)
            SyncCoordinator.shared.pushChange(for: id)
        } else {
            if item.budgetItem.frequency == .irregular {
                irregularConfirmItem = item
                return
            }
            let id = OccurrenceMatching.confirm(
                budgetItem: item.budgetItem,
                dueDate: item.dueDate,
                amount: item.amount,
                existingOccurrence: item.occurrence,
                in: modelContext
            )
            SyncCoordinator.shared.pushChange(for: id)
        }
    }

    private func scheduleNextIrregular(_ item: DashboardViewModel.UpcomingItem, nextDate: Date?) {
        let id = OccurrenceMatching.confirm(
            budgetItem: item.budgetItem,
            dueDate: item.dueDate,
            amount: item.amount,
            existingOccurrence: item.occurrence,
            in: modelContext
        )
        SyncCoordinator.shared.pushChange(for: id)

        if let nextDate {
            item.budgetItem.referenceDate = nextDate
        } else {
            // One-time payment — prevent any future occurrences by ending the item at this due date.
            item.budgetItem.endDate = item.dueDate
        }
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

    /// Auto-confirm items older than the lookback window
    private func autoConfirmOldItems() {
        let days = lookbackDays
        guard days > 0 else { return }

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        guard let cutoffDate = calendar.date(byAdding: .day, value: -days, to: today) else { return }

        // Pre-index existing occurrences by (budgetItemID, startOfDay) for O(1) lookup
        var existingOccurrenceKeys: Set<String> = []
        for occ in occurrences {
            guard let itemID = occ.budgetItem?.id else { continue }
            let dayKey = calendar.startOfDay(for: occ.dueDate)
            existingOccurrenceKeys.insert("\(itemID)_\(dayKey.timeIntervalSince1970)")
        }

        var insertedIDs: [UUID] = []

        for item in activeItems where item.frequency != .irregular {
            guard let scanStart = calendar.date(byAdding: .day, value: -30, to: cutoffDate) else { continue }
            let dates = DateCalculator.occurrenceDates(for: item, in: scanStart...cutoffDate)

            for date in dates where date < cutoffDate {
                let dayKey = calendar.startOfDay(for: date)
                let key = "\(item.id)_\(dayKey.timeIntervalSince1970)"

                if !existingOccurrenceKeys.contains(key) {
                    let occurrence = Occurrence(
                        dueDate: date,
                        expectedAmount: item.effectiveAmount(on: date),
                        status: .confirmed,
                        confirmedAt: Date(),
                        budgetItem: item
                    )
                    modelContext.insert(occurrence)
                    insertedIDs.append(occurrence.id)
                    existingOccurrenceKeys.insert(key)
                }
            }
        }

        guard !insertedIDs.isEmpty else { return }
        do {
            try modelContext.save()
            for id in insertedIDs {
                SyncCoordinator.shared.pushChange(for: id)
            }
        } catch {
            // Save failed — don't push unsaved records
        }
    }

    private func skipOccurrence(_ item: DashboardViewModel.UpcomingItem) {
        let id = OccurrenceMatching.toggleSkip(
            budgetItem: item.budgetItem,
            dueDate: item.dueDate,
            amount: item.amount,
            existingOccurrence: item.occurrence,
            in: modelContext
        )
        SyncCoordinator.shared.pushChange(for: id)
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
        ], inMemory: true)
}
