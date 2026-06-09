import SwiftUI
import SwiftData

struct BudgetItemListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \BudgetItem.sortOrder) private var allItems: [BudgetItem]
    @Query(sort: \FamilyMember.sortOrder) private var familyMembers: [FamilyMember]
    @State private var viewModel = BudgetItemListViewModel()
    @State private var showingAddSheet = false
    @State private var selectedFamilyMemberID: UUID?
    @State private var itemToClose: BudgetItem?

    var body: some View {
        NavigationStack {
            Group {
                if allItems.isEmpty {
                    ContentUnavailableView {
                        Label("No Budget Items", systemImage: "list.bullet.rectangle")
                    } description: {
                        Text("Add your recurring income and expenses to get started.")
                    } actions: {
                        Button {
                            showingAddSheet = true
                        } label: {
                            Text("Add First Item")
                        }
                        .buttonStyle(.glassProminent)
                    }
                } else {
                    List {
                        filterSection

                        let filtered = filteredByFamilyMember(viewModel.filteredItems(allItems))
                        ForEach(viewModel.sortedCategories) { category in
                            if let items = filtered[category], !items.isEmpty {
                                Section(category.displayName) {
                                    ForEach(items) { item in
                                        NavigationLink(value: item) {
                                            BudgetItemRowView(item: item)
                                        }
                                        .listRowBackground(ScribeTheme.surface.opacity(0.55))
                                        .swipeActions(edge: .trailing) {
                                            Button(role: .destructive) {
                                                let deletedID = item.id
                                                modelContext.delete(item)
                                                try? modelContext.save()
                                                SyncCoordinator.shared.pushDeletion(for: deletedID)
                                            } label: {
                                                Label("Delete", systemImage: "trash")
                                            }

                                            Button {
                                                item.isActive.toggle()
                                                item.modifiedAt = Date()
                                                try? modelContext.save()
                                                SyncCoordinator.shared.pushChange(for: item.id)
                                            } label: {
                                                Label(
                                                    item.isActive ? "Pause" : "Resume",
                                                    systemImage: item.isActive ? "pause.circle" : "play.circle"
                                                )
                                            }
                                            .tint(item.isActive ? .orange : ScribeTheme.success)
                                        }
                                        .swipeActions(edge: .leading) {
                                            if item.endDate != nil {
                                                Button {
                                                    item.endDate = nil
                                                    item.modifiedAt = Date()
                                                    try? modelContext.save()
                                                    SyncCoordinator.shared.pushChange(for: item.id)
                                                } label: {
                                                    Label("Reopen", systemImage: "arrow.uturn.backward.circle")
                                                }
                                                .tint(ScribeTheme.success)
                                            } else {
                                                Button {
                                                    itemToClose = item
                                                } label: {
                                                    Label("Close", systemImage: "xmark.circle")
                                                }
                                                .tint(ScribeTheme.error)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .searchable(text: $viewModel.searchText, prompt: "Search items")
                }
            }
            .scribeScreen()
            .navigationTitle("Budget Items")
            .navigationDestination(for: BudgetItem.self) { item in
                BudgetItemDetailView(item: item)
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingAddSheet = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingAddSheet) {
                BudgetItemFormView(mode: .create)
            }
            .sheet(item: $itemToClose) { item in
                CloseItemSheet(item: item)
            }
        }
    }

    private var filterSection: some View {
        VStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    FilterChip(title: "All", isSelected: viewModel.filterType == nil) {
                        viewModel.filterType = nil
                    }
                    FilterChip(title: "Income", isSelected: viewModel.filterType == .income) {
                        viewModel.filterType = .income
                    }
                    FilterChip(title: "Expense", isSelected: viewModel.filterType == .expense) {
                        viewModel.filterType = .expense
                    }
                }
                .padding(.horizontal)
            }

            if !familyMembers.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        FilterChip(title: "Everyone", isSelected: selectedFamilyMemberID == nil) {
                            selectedFamilyMemberID = nil
                        }
                        ForEach(familyMembers) { member in
                            FilterChip(title: member.name, isSelected: selectedFamilyMemberID == member.id) {
                                selectedFamilyMemberID = member.id
                            }
                        }
                    }
                    .padding(.horizontal)
                }
            }
        }
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
    }

    private func filteredByFamilyMember(_ grouped: [ItemCategory: [BudgetItem]]) -> [ItemCategory: [BudgetItem]] {
        guard let memberID = selectedFamilyMemberID else { return grouped }
        var result: [ItemCategory: [BudgetItem]] = [:]
        for (category, items) in grouped {
            let filtered = items.filter { $0.familyMembers.contains(where: { $0.id == memberID }) }
            if !filtered.isEmpty {
                result[category] = filtered
            }
        }
        return result
    }
}

private struct CloseItemSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    let item: BudgetItem

    @State private var endDate: Date = Date()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Close \"\(item.name)\" so it no longer appears in future periods.")
                        .foregroundStyle(ScribeTheme.secondaryText)
                }
                .scribeSection()

                Section("End Date") {
                    DatePicker("Last active date", selection: $endDate, displayedComponents: .date)
                }
                .scribeSection()
            }
            .scribeScreen()
            .navigationTitle("Close Item")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Close") {
                        item.endDate = endDate
                        item.modifiedAt = Date()
                        try? modelContext.save()
                        SyncCoordinator.shared.pushChange(for: item.id)
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

private struct FilterChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isSelected ? ScribeTheme.textOnPrimary : ScribeTheme.secondaryText)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                // Flat capsules — selected fills with the brand colour, unselected a
                // faint surface. Glass on chips this small just stacked tiny shadows.
                .background(
                    isSelected ? ScribeTheme.primary : ScribeTheme.surface.opacity(0.65),
                    in: .capsule
                )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

#Preview {
    BudgetItemListView()
        .modelContainer(for: [
            BudgetItem.self,
            AmountOverride.self,
            Occurrence.self,
            FamilyMember.self,
        ], inMemory: true)
}
