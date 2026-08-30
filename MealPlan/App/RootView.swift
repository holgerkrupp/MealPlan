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
    @Environment(\.modelContext) private var context
    @AppStorage(OnboardingPreferenceKeys.didCompleteOnboarding) private var didCompleteOnboarding = false
    @State private var selection: AppSection? = .plan
    @State private var showOnboarding = false
    @State private var didEvaluateOnboarding = false

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
        .alert(
            String(localized: "Recipe import"),
            isPresented: Binding(
                get: { appState.importNotice != nil },
                set: { if !$0 { appState.importNotice = nil } }
            )
        ) {
            Button(String(localized: "OK"), role: .cancel) {}
        } message: {
            Text(appState.importNotice ?? "")
        }
        .sheet(isPresented: $showOnboarding, onDismiss: { didCompleteOnboarding = true }) {
            OnboardingView()
                #if os(iOS)
                .interactiveDismissDisabled()
                #endif
        }
        .task { await evaluateOnboarding() }
    }

    /// Shows the first-run tour once, and only to someone who really is
    /// starting empty.
    private func evaluateOnboarding() async {
        guard !didEvaluateOnboarding else { return }
        didEvaluateOnboarding = true
        guard !didCompleteOnboarding else { return }

        // A device joining an existing household pulls its dishes down from
        // iCloud a moment after launch, so wait briefly before deciding —
        // otherwise returning users get the tour on every new device.
        if await hasDishes(waitingUpTo: .seconds(2)) {
            didCompleteOnboarding = true
            return
        }
        showOnboarding = true
    }

    private func hasDishes(waitingUpTo timeout: Duration) async -> Bool {
        let start = ContinuousClock.now
        while !Task.isCancelled {
            if ((try? context.fetchCount(FetchDescriptor<Dish>())) ?? 0) > 0 { return true }
            if ContinuousClock.now - start > timeout { return false }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return false
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
