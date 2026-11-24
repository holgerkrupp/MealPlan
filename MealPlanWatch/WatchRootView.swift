import SwiftUI

/// The watch's focused surfaces: swipe between plan, shopping and cooking.
///
/// Deliberately paged rather than a root menu — each surface is something one
/// opens mid-task, and a menu in front of it would cost a tap every time.
struct WatchRootView: View {

    private enum Tab: Hashable { case plan, shopping, cooking }

    @Environment(WatchDataStore.self) private var store
    @State private var tab: Tab = .plan

    var body: some View {
        TabView(selection: $tab) {
            NavigationStack {
                WatchPlanView()
            }
            .tag(Tab.plan)

            NavigationStack {
                WatchShoppingListView()
            }
            .tag(Tab.shopping)

            NavigationStack {
                WatchCookingTimersView()
            }
            .tag(Tab.cooking)
        }
        .tabViewStyle(.page)
    }
}

// MARK: - Shared pieces

/// Shown under a list that has nothing in it, saying which of the two reasons
/// it is: nothing planned, or nothing received yet.
struct WatchEmptyState: View {

    var symbol: String
    var title: String
    var message: String

    @Environment(WatchDataStore.self) private var store

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            Text(store.lastUpdated == nil ? waitingMessage : message)
        }
    }

    private var waitingMessage: String {
        store.isReachable
            ? String(localized: "Getting your plan from iPhone…")
            : String(localized: "Open MealPlan on your iPhone once to send your plan over.")
    }
}

/// The footer every screen ends with: when the phone last sent anything.
struct WatchSyncFooter: View {

    @Environment(WatchDataStore.self) private var store

    var body: some View {
        if let updated = store.lastUpdated {
            Text("Updated \(updated.formatted(.relative(presentation: .named)))")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .center)
                .listRowBackground(Color.clear)
        }
    }
}
