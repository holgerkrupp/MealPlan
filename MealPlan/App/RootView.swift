import SwiftUI
import SwiftData
import CloudKit

enum AppSection: String, CaseIterable, Identifiable, Hashable {
    case plan, dishes, shopping, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .plan: String(localized: "Plan")
        case .dishes: String(localized: "Dishes")
        case .shopping: String(localized: "Shopping list")
        case .settings: String(localized: "Settings")
        }
    }

    var symbol: String {
        switch self {
        case .plan: "calendar"
        case .dishes: "fork.knife"
        case .shopping: "cart"
        case .settings: "gearshape"
        }
    }

    /// What the sidebar and the tab bar offer. macOS leaves Settings out — it
    /// has a Settings window of its own, reached with ⌘, like every other app.
    static var navigationCases: [AppSection] {
        #if os(macOS)
        allCases.filter { $0 != .settings }
        #else
        allCases
        #endif
    }
}

@MainActor
struct RootView: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(AppState.self) private var appState
    @Environment(PurchaseManager.self) private var purchaseManager
    @Environment(\.modelContext) private var context
    @AppStorage(OnboardingPreferenceKeys.didCompleteOnboarding) private var didCompleteOnboarding = false
    @State private var selection: AppSection? = .plan
    @State private var showOnboarding = false
    @State private var didEvaluateOnboarding = false
    @State private var rootSheet: RootSheet?
    @State private var sharingErrorMessage: String?

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
                .dismissesOnOutsideClick()
                #if os(iOS)
                .interactiveDismissDisabled()
                #endif
        }
        .sheet(item: $rootSheet) { sheet in
            NavigationStack {
                sheet.content
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button(String(localized: "Done")) { rootSheet = nil }
                        }
                    }
            }
            #if os(macOS)
            .frame(minWidth: 520, minHeight: 460)
            #endif
            .dismissesOnOutsideClick()
        }
        .task { await evaluateOnboarding() }
        .task { await acceptPendingCloudShares() }
        .onReceive(NotificationCenter.default.publisher(for: .mealPlanDidReceiveCloudShare)) { _ in
            Task { await acceptPendingCloudShares() }
        }
        .task(id: appState.currentHousehold?.uuid) {
            await synchronizeHouseholdRegularly()
        }
        .alert(
            String(localized: "iCloud sharing needs attention"),
            isPresented: Binding(get: { sharingErrorMessage != nil }, set: { if !$0 { sharingErrorMessage = nil } })
        ) {
            Button(String(localized: "OK"), role: .cancel) {}
        } message: {
            Text(sharingErrorMessage ?? "")
        }
        // Everything the menu bar can reach from any section. Published here
        // rather than read from `AppState` directly so the menu items update —
        // and grey out — with the view hierarchy that owns them.
        .focusedSceneValue(\.appNavigation, AppNavigationCommands(
            section: selection ?? .plan,
            isGuest: appState.isGuest,
            select: { selection = $0 },
            newDish: { appState.handle(.addDish(url: nil, name: nil)) },
            showGettingStarted: { showOnboarding = true },
            showRegularMeals: { rootSheet = .regularMeals },
            showPantryStaples: { rootSheet = .pantryStaples },
            showDataTransfer: { rootSheet = .dataTransfer },
            undo: undoAction
        ))
    }

    /// The forgiving undo the plan offers after a destructive tap, lifted into
    /// the Edit menu. Nil — and so disabled — whenever no offer is standing.
    private var undoAction: (@MainActor () -> Void)? {
        guard let offer = appState.undoOffer else { return nil }
        return {
            offer.action()
            appState.undoOffer = nil
        }
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

    /// Accepts any CloudKit share invitations that arrived while the app had
    /// no `ModelContext` to accept them into yet (see `AppDelegate`), merging
    /// each into the store and switching to it.
    private func acceptPendingCloudShares() async {
        for metadata in HouseholdShareInvitationInbox.shared.drain() {
            do {
                let (household, isGuest) = try await HouseholdCloudSharingService.accept(metadata, context: context)
                appState.currentHousehold = household
                appState.isGuest = isGuest
                // Mirrors the household-specific half of `AppState.bootstrap`
                // rather than calling it outright: bootstrap re-fetches
                // "the first household", which could pick a different local
                // one if this device had already seeded its own.
                MealType.ensure(for: household, context: context)
                CookedLogMaintenance.run(for: household, context: context)
                MealRoutineScheduler.apply(
                    for: household,
                    context: context,
                    through: purchaseManager.latestPlanningDate(),
                    memberName: appState.currentMemberName
                )
            } catch {
                sharingErrorMessage = error.localizedDescription
            }
        }
    }

    /// Keeps both solo and shared households in sync through their per-record
    /// CloudKit zone while the app is open.
    private func synchronizeHouseholdRegularly() async {
        guard let household = appState.currentHousehold else { return }
        while !Task.isCancelled {
            do {
                try await HouseholdCloudSharingService.synchronize(household, context: context)
            } catch let cloudError as CKError where cloudError.code == .networkUnavailable || cloudError.code == .networkFailure {
                // Offline editing remains available; the next pass retries.
            } catch {
                sharingErrorMessage = error.localizedDescription
            }
            try? await Task.sleep(for: .seconds(8))
        }
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
            Tab(AppSection.settings.title, systemImage: AppSection.settings.symbol, value: .settings) {
                NavigationStack { SettingsView(layout: .stacked) }
            }
        }
    }

    private var splitView: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(AppSection.navigationCases) { section in
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
                case .settings: SettingsView(layout: .stacked)
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

/// Screens the menu bar can open from anywhere. Each normally lives a couple
/// of taps deep in Settings or Household, which is fine on a phone and far too
/// deep for a menu item.
enum RootSheet: String, Identifiable {
    case regularMeals, pantryStaples, dataTransfer

    var id: String { rawValue }

    @MainActor
    @ViewBuilder
    var content: some View {
        switch self {
        case .regularMeals: MealRoutinesView()
        case .pantryStaples: PantryStaplesView()
        case .dataTransfer: DataTransferView()
        }
    }
}
