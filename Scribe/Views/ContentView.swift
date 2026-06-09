import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            Tab("Dashboard", systemImage: "house") {
                DashboardView()
            }

            Tab("Items", systemImage: "list.bullet") {
                BudgetItemListView()
            }

            Tab("Settings", systemImage: "gearshape") {
                SettingsView()
            }
        }
        // Adaptive: compact iPhone tab bar, iPad/large sidebar.
        .tabViewStyle(.sidebarAdaptable)
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
