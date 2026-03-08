import SwiftUI
import SwiftData

struct BudgetItemListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \BudgetItem.sortOrder) private var allItems: [BudgetItem]
    @Query(sort: \FamilyMember.sortOrder) private var familyMembers: [FamilyMember]
    @State private var viewModel = BudgetItemListViewModel()
    @State private var showingAddSheet = false
    @State private var selectedFamilyMemberID: UUID?

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
                        .buttonStyle(.borderedProminent)
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
                                        .swipeActions(edge: .trailing) {
                                            Button(role: .destructive) {
                                                modelContext.delete(item)
                                                try? modelContext.save()
                                            } label: {
                                                Label("Delete", systemImage: "trash")
                                            }

                                            Button {
                                                item.isActive.toggle()
                                                item.modifiedAt = Date()
                                                try? modelContext.save()
                                            } label: {
                                                Label(
                                                    item.isActive ? "Pause" : "Resume",
                                                    systemImage: item.isActive ? "pause.circle" : "play.circle"
                                                )
                                            }
                                            .tint(item.isActive ? .orange : ScribeTheme.success)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .searchable(text: $viewModel.searchText, prompt: "Search items")
                }
            }
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

private struct FilterChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(isSelected ? .semibold : .regular))
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
        }
        .glassEffect(.regular.interactive(), in: .capsule)
        .opacity(isSelected ? 1.0 : 0.6)
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
