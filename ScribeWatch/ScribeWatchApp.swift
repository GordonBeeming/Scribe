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
            if newPhase == .background {
                WidgetCenter.shared.reloadAllTimelines()
            }
        }
    }
}
