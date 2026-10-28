import SwiftUI

private enum ScribeTab: String {
    case dashboard
    case items
    case settings
}

struct ContentView: View {
    @SceneStorage(ScribeApp.usesUITestFixture ? "ui-test.selectedTab" : "selectedTab") private var selectedTab: ScribeTab = .dashboard

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("Dashboard", systemImage: "house", value: ScribeTab.dashboard) {
                DashboardView()
            }

            Tab("Items", systemImage: "list.bullet", value: ScribeTab.items) {
                BudgetItemListView()
            }

            Tab("Settings", systemImage: "gearshape", value: ScribeTab.settings) {
                SettingsView()
            }
        }
        .tabViewStyle(.tabBarOnly)
        .tint(ScribeTheme.primary)
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [
            BudgetItem.self,
            AmountOverride.self,
            Occurrence.self,
            FamilyMember.self,
            DashboardSection.self,
        ], inMemory: true)
}
