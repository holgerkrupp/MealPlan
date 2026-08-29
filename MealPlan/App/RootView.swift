import SwiftUI
import SwiftData

enum AppSection: String, CaseIterable, Identifiable, Hashable {
    case plan, dishes, shopping, household, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .plan: String(localized: "Plan")
        case .dishes: String(localized: "Dishes")
        case .shopping: String(localized: "Shopping list")
        case .household: String(localized: "Household")
        case .settings: String(localized: "Settings")
        }
    }

    var symbol: String {
        switch self {
        case .plan: "calendar"
        case .dishes: "fork.knife"
        case .shopping: "cart"
        case .household: "person.2"
        case .settings: "gearshape"
        }
    }
}

@MainActor
struct RootView: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(AppState.self) private var appState
    @State private var selection: AppSection? = .plan

    var body: some View {
        Group {
            if sizeClass == .compact {
                compactTabs
            } else {
                splitView
            }
        }
        .onChange(of: appState.requestedSection) { _, requested in
            if let requested {
                selection = requested
                appState.requestedSection = nil
            }
        }
    }

    private var nonNilSelection: Binding<AppSection> {
        Binding(get: { selection ?? .plan }, set: { selection = $0 })
    }

    private var compactTabs: some View {
        TabView(selection: nonNilSelection) {
            Tab(AppSection.plan.title, systemImage: AppSection.plan.symbol, value: .plan) {
                NavigationStack { PlanView() }
            }
            Tab(AppSection.dishes.title, systemImage: AppSection.dishes.symbol, value: .dishes) {
                NavigationStack { DishLibraryView() }
            }
            Tab(AppSection.shopping.title, systemImage: AppSection.shopping.symbol, value: .shopping) {
                NavigationStack { ShoppingListView() }
            }
            Tab(AppSection.household.title, systemImage: AppSection.household.symbol, value: .household) {
                NavigationStack { HouseholdView() }
            }
            Tab(AppSection.settings.title, systemImage: AppSection.settings.symbol, value: .settings) {
                NavigationStack { SettingsView() }
            }
        }
    }

    private var splitView: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(AppSection.allCases) { section in
                    Label(section.title, systemImage: section.symbol)
                        .tag(section)
                }
            }
            .navigationTitle("MealPlan")
            #if os(macOS)
            .navigationSplitViewColumnWidth(min: 200, ideal: 220)
            #endif
        } detail: {
            NavigationStack {
                switch selection ?? .plan {
                case .plan: PlanView()
                case .dishes: DishLibraryView()
                case .shopping: ShoppingListView()
                case .household: HouseholdView()
                case .settings: SettingsView()
                }
            }
        }
    }
}

#Preview {
    RootView()
        .environment(AppState.preview)
        .modelContainer(PreviewData.container)
}
