import SwiftUI
import SwiftData

struct SettingsView: View {
    @State private var viewModel = SettingsViewModel()
    var body: some View {
        NavigationStack {
            Form {
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

                Section("Dashboard") {
                    NavigationLink("Dashboard Sections") {
                        DashboardSectionsView()
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
                    Button("Force Push All Data") {
                        SyncCoordinator.shared.pushAllLocalData()
                    }
                }

                DataManagementSection()

                Section("About") {
                    Text(AppVersion.fullVersionString)
                        .font(.footnote)
                        .foregroundStyle(ScribeTheme.secondaryText)
                        .frame(maxWidth: .infinity)
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
                        SyncCoordinator.shared.pushChange(for: member.id)
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
                    let deletedIDs = indexSet.map { familyMembers[$0].id }
                    for index in indexSet {
                        modelContext.delete(familyMembers[index])
                    }
                    try? modelContext.save()
                    for id in deletedIDs {
                        SyncCoordinator.shared.pushDeletion(for: id)
                    }
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
