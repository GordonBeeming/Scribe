import SwiftUI
import SwiftData
import os

private let dashboardLogger = Logger(subsystem: "com.gordonbeeming.scribe", category: "DashboardView")

struct DashboardView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Query(filter: #Predicate<BudgetItem> { $0.isActive }) private var activeItems: [BudgetItem]
    @Query private var allItems: [BudgetItem]
    @Query private var occurrences: [Occurrence]
    @Query(sort: \DashboardSection.sortOrder) private var dashboardSections: [DashboardSection]

    @State private var viewModel = DashboardViewModel()
    @State private var selectedItem: BudgetItem?
    @State private var irregularConfirmItem: DashboardViewModel.UpcomingItem?
    @State private var holidays: Set<Date> = []
    @State private var contentWidth: CGFloat?
    @State private var expandedWeeks: [WeekKey: Bool] = [:]

    private struct WeekKey: Hashable {
        let sectionID: UUID
        let startDate: Date
    }

    private var maximumContentWidth: CGFloat {
        let hasWeeklySection = dashboardSections.contains { $0.isEnabled && $0.sectionType == .detailedWeekly }
        return hasWeeklySection && !dynamicTypeSize.isAccessibilitySize ? 1120 : 760
    }

    private func weeklyColumns(for availableWidth: CGFloat?) -> [GridItem] {
        guard let contentWidth = availableWidth else {
            return [GridItem(.flexible(minimum: 0), spacing: ScribeDesign.Spacing.l)]
        }
        let width = min(contentWidth, maximumContentWidth)
        let minimum = dynamicTypeSize.isAccessibilitySize ? width : min(340, width)
        return [GridItem(.adaptive(minimum: minimum), spacing: ScribeDesign.Spacing.l)]
    }

    private var lookbackDays: Int {
        SettingsViewModel.currentLookbackDays()
    }

    private func adjustAmount(_ item: DashboardViewModel.UpcomingItem, newAmount: Decimal) {
        guard let occurrence = item.occurrence else { return }
        let id = OccurrenceMatching.adjustAmount(occurrence: occurrence, newAmount: newAmount, in: modelContext)
        SyncCoordinator.shared.pushChange(for: id)
    }

    var body: some View {
        let widthLimit = maximumContentWidth
        NavigationStack {
            ScrollView {
                Group {
                    if allItems.isEmpty {
                        emptyState
                    } else {
                        dashboardContent
                    }
                }
                .frame(maxWidth: widthLimit)
                .frame(minWidth: 0, maxWidth: .infinity)
                .padding(ScribeDesign.Spacing.l)
                .onGeometryChange(for: CGFloat.self) { geometry in
                    min(widthLimit, max(1, geometry.size.width - ScribeDesign.Spacing.l * 2))
                } action: { width in
                    contentWidth = width
                }
            }
            .scribeScreen()
            .task {
                guard !ScribeApp.usesUITestFixture else { return }
                dashboardLogger.info("DashboardView appeared: \(dashboardSections.count) sections, \(dashboardSections.filter(\.isEnabled).count) enabled")
                await loadHolidays()
                await ExchangeRateCache.shared.load()
                autoConfirmOldItems()
            }
            .navigationTitle("Scribe")
            .navigationBarTitleDisplayMode(horizontalSizeClass == .regular ? .inline : .large)
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
            } else if let width = contentWidth, width >= 620, !dynamicTypeSize.isAccessibilitySize,
                      enabledSections.contains(where: { $0.sectionType == .detailedWeekly }) {
                let weeklySections = enabledSections.filter { $0.sectionType == .detailedWeekly }
                let overviewWidth = min(300, max(240, width * 0.34))
                let paymentWidth = width - overviewWidth - ScribeDesign.Spacing.xl
                HStack(alignment: .top, spacing: ScribeDesign.Spacing.xl) {
                    VStack(alignment: .leading, spacing: ScribeDesign.Spacing.l) {
                        ScribeSectionHeader("Overview", systemImage: "chart.bar")
                        ForEach(enabledSections.filter { $0.sectionType == .monthlySummary }) { section in
                            sectionView(section, availableWidth: overviewWidth)
                        }
                        ForEach(weeklySections) { section in
                            WeeklyInsightsCard(
                                summary: viewModel.reconciliationSummary(groups: weeklyGroups(for: section)),
                                currencyCode: ExchangeRateCache.shared.baseCurrency,
                                sectionLabel: weeklySections.count > 1 ? section.label : nil
                            )
                        }
                    }
                    .frame(width: overviewWidth)
                    VStack(alignment: .leading, spacing: ScribeDesign.Spacing.xxl) {
                        ForEach(enabledSections.filter { $0.sectionType == .detailedWeekly }) { section in
                            sectionView(section, availableWidth: paymentWidth)
                        }
                    }
                    .frame(minWidth: 0, maxWidth: .infinity)
                }
            } else {
                VStack(spacing: ScribeDesign.Spacing.xxl) {
                    ForEach(enabledSections) { section in
                        sectionView(section, availableWidth: contentWidth)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func sectionView(_ section: DashboardSection, availableWidth: CGFloat?) -> some View {
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
                ),
                currencyCode: ExchangeRateCache.shared.baseCurrency
            )
        case .detailedWeekly:
            let groups = weeklyGroups(for: section)
            let calendar = Calendar.current
            let today = calendar.startOfDay(for: Date())
            VStack(alignment: .leading, spacing: ScribeDesign.Spacing.m) {
                ScribeSectionHeader(section.label, systemImage: "calendar.day.timeline.left")
                ForEach(groups.filter { $0.endDate < today }) { group in
                    weeklyCard(group, today: today, sectionID: section.id)
                }
                LazyVGrid(
                    columns: weeklyColumns(for: availableWidth),
                    alignment: .leading,
                    spacing: ScribeDesign.Spacing.l
                ) {
                    ForEach(groups.filter { $0.endDate >= today }) { group in
                        weeklyCard(group, today: today, sectionID: section.id)
                    }
                }
            }
        }
    }

    private func weeklyGroups(for section: DashboardSection) -> [DashboardViewModel.WeekGroup] {
        viewModel.weeklyGroups(
            budgetItems: activeItems,
            occurrences: occurrences,
            anchor: section.anchor,
            range: SettingsViewModel.currentDefaultRange(),
            holidays: holidays,
            exchangeRates: ExchangeRateCache.shared.rates,
            baseCurrency: ExchangeRateCache.shared.baseCurrency,
            rollingNet: SettingsViewModel.currentRollingWeeklyNet(),
            includingPreviousWeek: true
        )
    }

    private func weeklyCard(_ group: DashboardViewModel.WeekGroup, today: Date, sectionID: UUID) -> some View {
        let key = WeekKey(sectionID: sectionID, startDate: group.startDate)
        let isCurrentWeek = group.startDate <= today && group.endDate >= today
        return WeeklyBudgetCard(
            group: group,
            onConfirm: confirmOccurrence,
            onSkip: skipOccurrence,
            onTap: { selectedItem = $0.budgetItem },
            onAdjustAmount: adjustAmount,
            isCurrentWeek: isCurrentWeek,
            currencyCode: ExchangeRateCache.shared.baseCurrency,
            isExpanded: Binding(
                get: { expandedWeeks[key] ?? isCurrentWeek },
                set: { expandedWeeks[key] = $0 }
            )
        )
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
                dueDate: item.occurrenceDate,
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
            dueDate: item.occurrenceDate,
            amount: item.amount,
            existingOccurrence: item.occurrence,
            in: modelContext
        )
        SyncCoordinator.shared.pushChange(for: id)

        if let nextDate {
            item.budgetItem.referenceDate = nextDate
        } else {
            // One-time payment — prevent any future occurrences by ending the item at this due date.
            item.budgetItem.endDate = item.occurrenceDate
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
            let previousDates = await HolidayService.shared.holidayDates(for: code, year: year - 1)
            allHolidays.formUnion(previousDates)
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
        guard let cutoffDate = viewModel.autoConfirmationCutoff(
            lookbackDays: days,
            budgetItems: activeItems,
            sections: dashboardSections,
            range: SettingsViewModel.currentDefaultRange(),
            holidays: holidays,
            now: today
        ) else { return }

        // Pre-index existing occurrences by (budgetItemID, startOfDay) for O(1) lookup
        var existingOccurrenceKeys: Set<String> = []
        for occ in occurrences {
            guard let itemID = occ.budgetItem?.id else { continue }
            let dayKey = calendar.startOfDay(for: occ.dueDate)
            existingOccurrenceKeys.insert("\(itemID)_\(dayKey.timeIntervalSince1970)")
        }

        var insertedIDs: [UUID] = []

        for item in activeItems where item.frequency != .irregular {
            let dates = viewModel.autoConfirmationDates(for: item, before: cutoffDate, holidays: holidays)

            for date in dates {
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
            dueDate: item.occurrenceDate,
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
