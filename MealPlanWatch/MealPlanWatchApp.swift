import SwiftUI

/// MealPlan on the wrist: the shopping list to walk a shop with, and the next
/// planned dishes to glance at.
///
/// Nothing is planned or edited here — that stays on the phone, where there is
/// room for it. The one thing the watch writes is a tick on a shopping line,
/// which is exactly the thing one wants to do with a full basket in the other
/// hand.
@main
struct MealPlanWatchApp: App {

    @State private var store = WatchDataStore.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .environment(store)
                .task { store.start() }
                .onChange(of: scenePhase) { _, phase in
                    // Coming back to the app is the moment its data is most
                    // likely to be stale — and the moment it matters.
                    guard phase == .active else { return }
                    store.refresh()
                }
        }
    }
}
