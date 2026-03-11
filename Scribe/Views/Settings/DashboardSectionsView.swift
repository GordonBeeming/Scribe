import SwiftUI
import SwiftData

struct DashboardSectionsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \DashboardSection.sortOrder) private var sections: [DashboardSection]
    @Query(filter: #Predicate<BudgetItem> { $0.itemType == "income" && $0.isActive }) private var incomeItems: [BudgetItem]
    @State private var showingAddSheet = false

    var body: some View {
        List {
            ForEach(sections) { section in
                NavigationLink {
                    DashboardSectionEditView(section: section, incomeItems: incomeItems)
                } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(section.label)
                                .font(.headline)
                            Text(section.sectionType.displayName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { section.isEnabled },
                            set: { newValue in
                                section.isEnabled = newValue
                                section.modifiedAt = Date()
                                try? modelContext.save()
                                SyncCoordinator.shared.pushChange(for: section.id)
                            }
                        ))
                        .labelsHidden()
                    }
                }
            }
            .onMove { source, destination in
                var ordered = sections.sorted(by: { $0.sortOrder < $1.sortOrder })
                ordered.move(fromOffsets: source, toOffset: destination)
                for (index, section) in ordered.enumerated() {
                    section.sortOrder = index
                    section.modifiedAt = Date()
                }
                try? modelContext.save()
                for section in ordered {
                    SyncCoordinator.shared.pushChange(for: section.id)
                }
            }
            .onDelete { offsets in
                let toDelete = offsets.map { sections[$0] }
                for section in toDelete {
                    let id = section.id
                    modelContext.delete(section)
                    try? modelContext.save()
                    SyncCoordinator.shared.pushDeletion(for: id)
                }
            }
        }
        .navigationTitle("Dashboard Sections")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingAddSheet = true
                } label: {
                    Image(systemName: "plus")
                }
            }
            ToolbarItem(placement: .topBarLeading) {
                EditButton()
            }
        }
        .sheet(isPresented: $showingAddSheet) {
            DashboardSectionAddView(incomeItems: incomeItems, existingCount: sections.count)
        }
    }
}

struct DashboardSectionAddView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let incomeItems: [BudgetItem]
    let existingCount: Int

    @State private var label = ""
    @State private var sectionType: DashboardSectionType = .detailedWeekly
    @State private var anchorMode: AnchorMode = .fixedDay
    @State private var fixedWeekday: Int = 2 // Monday
    @State private var fixedDayOfMonth: Int = 1
    @State private var linkedIncomeID: UUID?

    enum AnchorMode: String, CaseIterable {
        case fixedDay = "Fixed Weekday"
        case fixedDayOfMonth = "Fixed Day of Month"
        case linkedIncome = "Linked to Income"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Label") {
                    TextField("Section name", text: $label)
                }

                Section("Type") {
                    Picker("Section Type", selection: $sectionType) {
                        ForEach(DashboardSectionType.allCases) { type in
                            Text(type.displayName).tag(type)
                        }
                    }
                }

                Section("Anchor") {
                    Picker("Anchor Type", selection: $anchorMode) {
                        ForEach(AnchorMode.allCases, id: \.rawValue) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }

                    switch anchorMode {
                    case .fixedDay:
                        Picker("Weekday", selection: $fixedWeekday) {
                            Text("Sunday").tag(1)
                            Text("Monday").tag(2)
                            Text("Tuesday").tag(3)
                            Text("Wednesday").tag(4)
                            Text("Thursday").tag(5)
                            Text("Friday").tag(6)
                            Text("Saturday").tag(7)
                        }
                    case .fixedDayOfMonth:
                        Picker("Day", selection: $fixedDayOfMonth) {
                            ForEach(1...31, id: \.self) { day in
                                Text("\(day)").tag(day)
                            }
                        }
                    case .linkedIncome:
                        if incomeItems.isEmpty {
                            Text("No income items available")
                                .foregroundStyle(.secondary)
                        } else {
                            Picker("Income Item", selection: $linkedIncomeID) {
                                Text("Select...").tag(nil as UUID?)
                                ForEach(incomeItems) { item in
                                    Text(item.name).tag(item.id as UUID?)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Add Section")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        addSection()
                        dismiss()
                    }
                    .disabled(label.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func addSection() {
        let anchor: DashboardSectionAnchor
        switch anchorMode {
        case .fixedDay:
            anchor = .fixedDay(weekday: fixedWeekday)
        case .fixedDayOfMonth:
            anchor = .fixedDayOfMonth(day: fixedDayOfMonth)
        case .linkedIncome:
            anchor = .linkedIncome(budgetItemID: linkedIncomeID ?? UUID())
        }

        let section = DashboardSection(
            sectionType: sectionType,
            anchor: anchor,
            sortOrder: existingCount,
            label: label.trimmingCharacters(in: .whitespaces)
        )
        modelContext.insert(section)
        try? modelContext.save()
        SyncCoordinator.shared.pushChange(for: section.id)
    }
}

struct DashboardSectionEditView: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var section: DashboardSection
    let incomeItems: [BudgetItem]

    @State private var label: String = ""
    @State private var sectionType: DashboardSectionType = .detailedWeekly
    @State private var anchorMode: DashboardSectionAddView.AnchorMode = .fixedDay
    @State private var fixedWeekday: Int = 2
    @State private var fixedDayOfMonth: Int = 1
    @State private var linkedIncomeID: UUID?

    var body: some View {
        Form {
            Section("Label") {
                TextField("Section name", text: $label)
            }

            Section("Type") {
                Picker("Section Type", selection: $sectionType) {
                    ForEach(DashboardSectionType.allCases) { type in
                        Text(type.displayName).tag(type)
                    }
                }
            }

            Section("Anchor") {
                Picker("Anchor Type", selection: $anchorMode) {
                    ForEach(DashboardSectionAddView.AnchorMode.allCases, id: \.rawValue) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }

                switch anchorMode {
                case .fixedDay:
                    Picker("Weekday", selection: $fixedWeekday) {
                        Text("Sunday").tag(1)
                        Text("Monday").tag(2)
                        Text("Tuesday").tag(3)
                        Text("Wednesday").tag(4)
                        Text("Thursday").tag(5)
                        Text("Friday").tag(6)
                        Text("Saturday").tag(7)
                    }
                case .fixedDayOfMonth:
                    Picker("Day", selection: $fixedDayOfMonth) {
                        ForEach(1...31, id: \.self) { day in
                            Text("\(day)").tag(day)
                        }
                    }
                case .linkedIncome:
                    if incomeItems.isEmpty {
                        Text("No income items available")
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Income Item", selection: $linkedIncomeID) {
                            Text("Select...").tag(nil as UUID?)
                            ForEach(incomeItems) { item in
                                Text(item.name).tag(item.id as UUID?)
                            }
                        }
                    }
                }
            }

            Section {
                Toggle("Enabled", isOn: Binding(
                    get: { section.isEnabled },
                    set: { newValue in
                        section.isEnabled = newValue
                        section.modifiedAt = Date()
                        try? modelContext.save()
                        SyncCoordinator.shared.pushChange(for: section.id)
                    }
                ))
            }
        }
        .navigationTitle("Edit Section")
        .onAppear {
            label = section.label
            sectionType = section.sectionType
            switch section.anchor {
            case .fixedDay(let weekday):
                anchorMode = .fixedDay
                fixedWeekday = weekday
            case .fixedDayOfMonth(let day):
                anchorMode = .fixedDayOfMonth
                fixedDayOfMonth = day
            case .linkedIncome(let id):
                anchorMode = .linkedIncome
                linkedIncomeID = id
            }
        }
        .onChange(of: label) { applyChanges() }
        .onChange(of: sectionType) { applyChanges() }
        .onChange(of: anchorMode) { applyChanges() }
        .onChange(of: fixedWeekday) { applyChanges() }
        .onChange(of: fixedDayOfMonth) { applyChanges() }
        .onChange(of: linkedIncomeID) { applyChanges() }
    }

    private func applyChanges() {
        section.label = label
        section.sectionType = sectionType
        let anchor: DashboardSectionAnchor
        switch anchorMode {
        case .fixedDay:
            anchor = .fixedDay(weekday: fixedWeekday)
        case .fixedDayOfMonth:
            anchor = .fixedDayOfMonth(day: fixedDayOfMonth)
        case .linkedIncome:
            anchor = .linkedIncome(budgetItemID: linkedIncomeID ?? UUID())
        }
        section.anchor = anchor
        section.modifiedAt = Date()
        try? modelContext.save()
        SyncCoordinator.shared.pushChange(for: section.id)
    }
}
