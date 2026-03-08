import SwiftUI
import SwiftData

struct BudgetItemFormView: View {
    enum Mode {
        case create
        case edit(BudgetItem)
    }

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \FamilyMember.sortOrder) private var familyMembers: [FamilyMember]

    let mode: Mode
    @State private var viewModel = BudgetItemDetailViewModel()
    @State private var amountText: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Basic Info") {
                    TextField("Name", text: $viewModel.name)

                    Picker("Type", selection: $viewModel.itemType) {
                        ForEach(ItemType.allCases) { type in
                            Text(type.displayName).tag(type)
                        }
                    }

                    HStack {
                        Text(currencySymbol)
                        TextField("Amount", text: $amountText)
                            .keyboardType(.decimalPad)
                            .onChange(of: amountText) {
                                if let value = Decimal(string: amountText) {
                                    viewModel.amount = value
                                }
                            }
                    }

                    Picker("Currency", selection: $viewModel.currencyCode) {
                        ForEach(CurrencyFormatter.supportedCurrencies, id: \.code) { currency in
                            Text("\(currency.code) - \(currency.name)").tag(currency.code)
                        }
                    }
                }

                Section("Schedule") {
                    FrequencyPicker(
                        frequency: $viewModel.frequency,
                        dayOfMonth: $viewModel.dayOfMonth,
                        referenceDate: $viewModel.referenceDate
                    )
                }

                Section("Category") {
                    Picker("Category", selection: $viewModel.category) {
                        ForEach(ItemCategory.allCases) { cat in
                            Label(cat.displayName, systemImage: cat.systemImage).tag(cat)
                        }
                    }
                }

                if viewModel.itemType == .income {
                    Section("Display") {
                        Toggle("Show Last in Day", isOn: $viewModel.showLast)
                    }
                }

                if !familyMembers.isEmpty {
                    Section("Family Members") {
                        ForEach(familyMembers) { member in
                            Toggle(member.name, isOn: Binding(
                                get: { viewModel.selectedFamilyMemberIDs.contains(member.id) },
                                set: { selected in
                                    if selected {
                                        viewModel.selectedFamilyMemberIDs.insert(member.id)
                                    } else {
                                        viewModel.selectedFamilyMemberIDs.remove(member.id)
                                    }
                                }
                            ))
                        }
                    }
                }

                Section {
                    Toggle("Active", isOn: $viewModel.isActive)
                }

                Section("Notes") {
                    TextField("Notes (optional)", text: $viewModel.notes, axis: .vertical)
                        .lineLimit(3...6)
                }
            }
            .navigationTitle(isEditing ? "Edit Item" : "New Item")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save()
                        dismiss()
                    }
                    .disabled(!viewModel.isValid)
                }
            }
            .onAppear {
                if case .edit(let item) = mode {
                    viewModel.loadFromItem(item)
                    amountText = "\(item.amount)"
                }
            }
        }
    }

    private var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    private var currencySymbol: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = viewModel.currencyCode
        return formatter.currencySymbol ?? "$"
    }

    private func save() {
        switch mode {
        case .create:
            let item = viewModel.createItem()
            viewModel.applyFamilyMembers(to: item, allMembers: familyMembers)
            modelContext.insert(item)
        case .edit(let item):
            viewModel.applyToItem(item)
            viewModel.applyFamilyMembers(to: item, allMembers: familyMembers)
        }
        try? modelContext.save()
    }
}

#Preview {
    BudgetItemFormView(mode: .create)
        .modelContainer(for: [
            BudgetItem.self,
            AmountOverride.self,
            Occurrence.self,
            FamilyMember.self,
        ], inMemory: true)
}
