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
                        // every item's headline amount up to date. The refreshed
                        // amount is derived state that every device recomputes,
                        // so it is not pushed; pushing it made a stale device
                        // overwrite the other member's real edits.
                        let context = SharedModelContainer.shared.mainContext
                        BudgetItemAmountRefresher.backfillBaselineOverrides(in: context)
                        BudgetItemAmountRefresher.refreshAll(in: context)
                    }
                }
        }
        .modelContainer(SharedModelContainer.shared)
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                if !isTestEnvironment {
                    let context = SharedModelContainer.shared.mainContext
                    BudgetItemAmountRefresher.refreshAll(in: context)
                    // Silent pushes are best-effort, so a foreground is the one
                    // moment we know the user is looking and can ask for the
                    // other member's changes explicitly.
                    SyncCoordinator.shared.fetchAllChanges()
                }
            case .background:
                WidgetCenter.shared.reloadAllTimelines()
            default:
                break
            }
        }
    }
}
