import SwiftUI
import SwiftData
import WidgetKit

@main
struct ScribeApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    static var usesUITestFixture: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--ui-testing")
        #else
        false
        #endif
    }

    private let modelContainer = Self.makeModelContainer()

    @MainActor
    private static func makeModelContainer() -> ModelContainer {
        #if DEBUG
        if usesUITestFixture {
            do {
                let config = ModelConfiguration(schema: SharedModelContainer.schema,
                                                isStoredInMemoryOnly: true, cloudKitDatabase: .none)
                let container = try ModelContainer(for: SharedModelContainer.schema, configurations: [config])
                DemoDataGenerator.generate(in: container.mainContext, syncToCloud: false)
                try container.mainContext.save()
                return container
            } catch {
                fatalError("Unable to create the isolated UI test store: \(error)")
            }
        }
        #endif
        return SharedModelContainer.shared
    }

    private var isTestEnvironment: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil || Self.usesUITestFixture
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .accessibilityIdentifier(Self.usesUITestFixture ? "ui-test-fixture" : "scribe-root")
                .onAppear {
                    if !isTestEnvironment {
                        SyncCoordinator.shared.start(with: modelContainer)
                        // Ensure UserPreferences model exists (migrates from UserDefaults)
                        let vm = SettingsViewModel(modelContext: modelContainer.mainContext)
                        vm.ensurePreferencesExist()
                        vm.ensureDefaultDashboardSectionsExist()
                        // Backfill baseline overrides for items created before
                        // amount history was tracked from day one, then bring
                        // every item's headline amount up to date. The refreshed
                        // amount is derived state that every device recomputes,
                        // so it is not pushed; pushing it made a stale device
                        // overwrite the other member's real edits.
                        let context = modelContainer.mainContext
                        BudgetItemAmountRefresher.backfillBaselineOverrides(in: context)
                        BudgetItemAmountRefresher.refreshAll(in: context)
                    }
                }
        }
        .modelContainer(modelContainer)
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                if !isTestEnvironment {
                    let context = modelContainer.mainContext
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
