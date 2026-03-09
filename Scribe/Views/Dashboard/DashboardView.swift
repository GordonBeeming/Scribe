import SwiftUI
import SwiftData

struct DashboardView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(filter: #Predicate<BudgetItem> { $0.isActive }) private var activeItems: [BudgetItem]
    @Query private var allItems: [BudgetItem]
    @Query private var occurrences: [Occurrence]

    @State private var viewModel = DashboardViewModel()
    @State private var selectedItem: BudgetItem?
    @State private var irregularConfirmItem: DashboardViewModel.UpcomingItem?

    var body: some View {
        NavigationStack {
            ScrollView {
                if allItems.isEmpty {
                    emptyState
                } else {
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
                            onTap: { selectedItem = $0.budgetItem }
                        )
                    }
                    .padding()
                }
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
        ], inMemory: true)
}
