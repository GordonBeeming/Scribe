import SwiftUI
import SwiftData

struct SettingsView: View {
    @State private var viewModel = SettingsViewModel()
    @Environment(\.modelContext) private var modelContext
    @State private var seedDataLoaded = SeedData.hasLoaded

    var body: some View {
        NavigationStack {
            Form {
                if !seedDataLoaded {
                    Section("Dev Tools") {
                        Button("Load Sample Budget Data") {
                            SeedData.loadAll(into: modelContext)
                            seedDataLoaded = true
                        }
                    }
                }

                Section("Defaults") {
                    Picker("Default Period Range", selection: $viewModel.defaultRange) {
                        ForEach(DefaultRange.allCases) { range in
                            Text(range.displayName).tag(range)
                        }
                    }

                    Picker("Default Currency", selection: $viewModel.defaultCurrency) {
                        ForEach(CurrencyFormatter.supportedCurrencies, id: \.code) { currency in
                            Text("\(currency.code) - \(currency.name)").tag(currency.code)
                        }
                    }
                }

                Section("Family Members") {
                    NavigationLink("Manage Family Members") {
                        FamilyMemberManagementView()
                    }
                }

                Section("Family Sharing") {
                    NavigationLink("Manage Sharing") {
                        SharingView()
                    }
                }

                Section("Sync") {
                    SyncStatusRow()
                }

                Section("About") {
                    LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                    LabeledContent("Build", value: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1")
                }
            }
            .navigationTitle("Settings")
        }
    }
}

// MARK: - Family Member Management

struct FamilyMemberManagementView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \FamilyMember.sortOrder) private var familyMembers: [FamilyMember]
    @State private var newMemberName = ""

    var body: some View {
        List {
            Section {
                HStack {
                    TextField("Name", text: $newMemberName)
                    Button("Add") {
                        guard !newMemberName.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                        let member = FamilyMember(
                            name: newMemberName.trimmingCharacters(in: .whitespaces),
                            sortOrder: familyMembers.count
                        )
                        modelContext.insert(member)
                        try? modelContext.save()
                        newMemberName = ""
                    }
                    .disabled(newMemberName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            Section {
                ForEach(familyMembers) { member in
                    Text(member.name)
                }
                .onDelete { indexSet in
                    for index in indexSet {
                        modelContext.delete(familyMembers[index])
                    }
                    try? modelContext.save()
                }
            }
        }
        .navigationTitle("Family Members")
    }
}

private struct SyncStatusRow: View {
    var body: some View {
        let status = SyncCoordinator.shared.syncStatus
        HStack {
            Text("CloudKit Sync")
            Spacer()
            switch status {
            case .idle:
                Image(systemName: "minus.circle")
                    .foregroundStyle(ScribeTheme.secondaryText)
                Text("Idle")
                    .foregroundStyle(ScribeTheme.secondaryText)
            case .syncing:
                ProgressView()
                    .controlSize(.small)
                Text("Syncing")
                    .foregroundStyle(ScribeTheme.secondaryText)
            case .synced:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(ScribeTheme.success)
                Text("Active")
                    .foregroundStyle(ScribeTheme.secondaryText)
            case .error(let message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(ScribeTheme.error)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(ScribeTheme.error)
                    .lineLimit(1)
            }
        }
    }
}

#Preview {
    SettingsView()
}
