import SwiftUI
import SwiftData
import WidgetKit

@main
struct ScribeWatchApp: App {
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            BudgetSummaryView()
                .onAppear {
                    SyncCoordinator.shared.start(with: SharedModelContainer.shared)
                }
        }
        .modelContainer(SharedModelContainer.shared)
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                // The watch rarely receives silent pushes; raising the wrist is
                // the moment to pull the phone's and the other member's changes.
                SyncCoordinator.shared.fetchAllChanges()
            case .background:
                WidgetCenter.shared.reloadAllTimelines()
            default:
                break
            }
        }
    }
}
