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

            Tab("Quick Add", systemImage: "bolt.fill") {
                QuickAddView()
            }

            Tab("Period", systemImage: "calendar") {
                PeriodView()
            }

            Tab("Settings", systemImage: "gearshape") {
                SettingsView()
            }
        }
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
            QuickAdjustment.self,
        ], inMemory: true)
}
