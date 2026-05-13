import SwiftUI
import SwiftData
import WidgetKit

@main
struct ScribeApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    private var isTestEnvironment: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onAppear {
                    if !isTestEnvironment {
                        SyncCoordinator.shared.start(with: SharedModelContainer.shared)
                        // Ensure UserPreferences model exists (migrates from UserDefaults)
                        let vm = SettingsViewModel(modelContext: SharedModelContainer.shared.mainContext)
                        vm.ensurePreferencesExist()
                        vm.ensureDefaultDashboardSectionsExist()
                        // Backfill baseline overrides for items created before
                        // amount history was tracked from day one, then bring
                        // every item's headline amount up to date.
                        let context = SharedModelContainer.shared.mainContext
                        BudgetItemAmountRefresher.backfillBaselineOverrides(in: context)
                        let changed = BudgetItemAmountRefresher.refreshAll(in: context)
                        for id in changed {
                            SyncCoordinator.shared.pushChange(for: id)
                        }
                    }
                }
        }
        .modelContainer(SharedModelContainer.shared)
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                if !isTestEnvironment {
                    let context = SharedModelContainer.shared.mainContext
                    let changed = BudgetItemAmountRefresher.refreshAll(in: context)
                    for id in changed {
                        SyncCoordinator.shared.pushChange(for: id)
                    }
                }
            case .background:
                WidgetCenter.shared.reloadAllTimelines()
            default:
                break
            }
        }
    }
}
