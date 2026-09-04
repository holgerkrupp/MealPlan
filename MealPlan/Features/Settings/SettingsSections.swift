import SwiftUI
import SwiftData
import ESADesignKit

// The individual blocks of Settings, each one self-contained so the same code
// can be stacked into one scrolling form (iOS) or dealt out across the panes of
// a Settings window (macOS). Every section reads what it needs from the
// environment, so a pane is just a list of the sections that belong in it.

// MARK: - Unlock

@MainActor
struct UnlockSettingsSection: View {
    @Environment(PurchaseManager.self) private var purchaseManager
    @State private var showingPaywall = false

    var body: some View {
        if !purchaseManager.isUnlocked {
            Section {
                Button {
                    showingPaywall = true
                } label: {
                    Label(String(localized: "Unlock App"), systemImage: "lock.open")
                }
            } footer: {
                Text("Unlock unlimited planning with a one-time purchase.")
            }
            .sheet(isPresented: $showingPaywall) {
                PaywallView()
                    .dismissesOnOutsideClick()
            }
        }
    }
}

// MARK: - Household

@MainActor
struct HouseholdSettingsSection: View {
    var body: some View {
        Section {
            NavigationLink {
                HouseholdSettingsView()
            } label: {
                Label(String(localized: "Household"), systemImage: "person.2")
            }
        }
    }
}

// MARK: - Units

@MainActor
struct UnitsSettingsSection: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var context

    var body: some View {
        if let household = appState.currentHousehold {
            Section {
                Picker(String(localized: "Show amounts in"), selection: unitSystem(household)) {
                    ForEach(UnitSystem.allCases) { system in
                        Text(system.localizedName).tag(system)
                    }
                }
                Toggle(
                    String(localized: "Round scaled and converted amounts"),
                    isOn: roundsAmounts(household)
                )
            } header: {
                Text(String(localized: "Units"))
            } footer: {
                Text("Uses practical kitchen increments, including whole eggs. Turn off to show exact values.")
            }
        }
    }

    private func unitSystem(_ household: Household) -> Binding<UnitSystem> {
        Binding(
            get: { household.unitSystem },
            set: { value in
                household.unitSystem = value
                ShoppingListBuilder.refreshDisplayText(
                    for: household.shoppingItems ?? [],
                    system: value,
                    roundsAmounts: household.roundsDisplayedAmounts
                )
                try? context.save()
            }
        )
    }

    private func roundsAmounts(_ household: Household) -> Binding<Bool> {
        Binding(
            get: { household.roundsDisplayedAmounts },
            set: { value in
                household.roundsDisplayedAmounts = value
                ShoppingListBuilder.refreshDisplayText(
                    for: household.shoppingItems ?? [],
                    system: household.unitSystem,
                    roundsAmounts: value
                )
                try? context.save()
            }
        )
    }
}

// MARK: - Nutrition

/// Estimated energy and macros: whether to show them at all, and in which
/// unit.
///
/// The off switch is not a formality. Calories on a family calendar are
/// unwelcome in plenty of households, and a meal planner has to work just as
/// well for them — so one toggle removes every figure from the recipe screen,
/// the meal cards and the day headers at once.
@MainActor
struct NutritionSettingsSection: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var context

    var body: some View {
        if let household = appState.currentHousehold {
            Section {
                Toggle(
                    String(localized: "Show nutrition estimates"),
                    isOn: showsEstimates(household)
                )
                if household.showsNutritionEstimates {
                    Picker(String(localized: "Energy in"), selection: energyUnit(household)) {
                        ForEach(EnergyUnit.allCases) { unit in
                            Text(unit.localizedName).tag(unit)
                        }
                    }
                }
            } header: {
                Text(String(localized: "Nutrition"))
            } footer: {
                Text("Worked out from each recipe's ingredients using average reference values, so figures are rough — a planning aid, not a nutrition label. Add your own values to an ingredient from the recipe screen.")
            }
        }
    }

    private func showsEstimates(_ household: Household) -> Binding<Bool> {
        Binding(
            get: { household.showsNutritionEstimates },
            set: { household.showsNutritionEstimates = $0; try? context.save() }
        )
    }

    private func energyUnit(_ household: Household) -> Binding<EnergyUnit> {
        Binding(
            get: { household.energyUnit },
            set: { household.energyUnit = $0; try? context.save() }
        )
    }
}

// MARK: - Plan

/// The way into the meal editor where Meals isn't its own pane.
@MainActor
struct PlanSettingsSection: View {
    /// `false` on macOS, where Meals is its own pane in the sidebar.
    var showsMealsLink = true
    /// `nil` where the pane title already says what this is.
    var header: String? = String(localized: "Calendar")

    @Environment(AppState.self) private var appState

    var body: some View {
        if let household = appState.currentHousehold {
            Section {
                if showsMealsLink {
                    NavigationLink {
                        MealsSettingsView()
                    } label: {
                        LabeledContent(String(localized: "Meals"), value: mealsSummary(household))
                    }
                }
            } header: {
                if let header {
                    Text(header)
                }
            }
        }
    }

    private func mealsSummary(_ household: Household) -> String {
        let names = household.sortedMealTypes.map(\.name).filter { !$0.isEmpty }
        return names.isEmpty ? String(localized: "None") : names.joined(separator: ", ")
    }
}

// MARK: - Recipe search

@MainActor
struct RecipeSearchSettingsSection: View {
    @AppStorage("search.engine") private var searchEngineRaw = SearchEngine.fallback.rawValue

    var body: some View {
        Section {
            Picker(String(localized: "Search with"), selection: $searchEngineRaw) {
                ForEach(SearchEngine.allCases) { engine in
                    Text(engine.localizedName).tag(engine.rawValue)
                }
            }
        } header: {
            Text("Recipe search")
        } footer: {
            Text("Used by “Find a recipe”. iOS doesn’t tell apps which search engine you prefer, so pick one here.")
        }
    }
}

// MARK: - Reminders

@MainActor
struct RemindersSettingsSection: View {
    @Environment(\.modelContext) private var context

    @State private var dinnerReminder = MealNotificationScheduler.shared.dinnerEnabled
    @State private var reminderTime: Date = Calendar.current.date(
        bySettingHour: MealNotificationScheduler.shared.dinnerHour, minute: 0, second: 0, of: .now
    ) ?? .now

    var body: some View {
        Section(String(localized: "Reminders")) {
            Toggle(String(localized: "Remind me about tonight’s dinner"), isOn: $dinnerReminder)
            if dinnerReminder {
                DatePicker(
                    String(localized: "At"),
                    selection: $reminderTime,
                    displayedComponents: .hourAndMinute
                )
            }
        }
        .onChange(of: dinnerReminder) { _, on in
            let scheduler = MealNotificationScheduler.shared
            scheduler.dinnerEnabled = on
            scheduler.settingsChanged(context: context)
        }
        .onChange(of: reminderTime) { _, time in
            let scheduler = MealNotificationScheduler.shared
            scheduler.dinnerHour = Calendar.current.component(.hour, from: time)
            scheduler.settingsChanged(context: context)
        }
    }
}

// MARK: - Bring!

/// Only used where Bring! isn't a pane of its own.
@MainActor
struct BringSettingsSection: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Section {
            NavigationLink {
                BringSettingsView()
            } label: {
                LabeledContent {
                    Text(status)
                } label: {
                    Label(String(localized: "Bring!"), systemImage: "cart")
                }
            }
        } header: {
            Text("Shopping")
        } footer: {
            Text("Send your shopping list to Bring!, or keep the two in step so ticking something off in either app ticks it off in the other.")
        }
    }

    private var status: String {
        guard BringSyncService.shared.hasAccount,
              let name = appState.currentHousehold?.bringListName,
              appState.currentHousehold?.isConnectedToBring == true
        else { return String(localized: "Not connected") }
        return name
    }
}

// MARK: - Data

/// Only used where backup and restore aren't a pane of their own.
@MainActor
struct DataSettingsSection: View {
    var body: some View {
        Section {
            NavigationLink {
                DataTransferView()
            } label: {
                Label(String(localized: "Data"), systemImage: "externaldrive")
            }
        } footer: {
            Text("Back up everything to a file, or restore one — the way to carry your library into a build that syncs with a different iCloud database.")
        }
    }
}

// MARK: - About

@MainActor
struct AboutSettingsSection: View {
    @State private var showingOnboarding = false

    var body: some View {
        Group {
            Section {
                Button {
                    showingOnboarding = true
                } label: {
                    Label(String(localized: "Getting started"), systemImage: "sparkles")
                }
            } footer: {
                Text("A short tour of the plan, the dish library, and how to share recipes into MealPlan from other apps.")
            }

            Section {
                LabeledContent(String(localized: "Version"), value: Self.appVersion)
            } footer: {
                Text("Your plan and dishes are stored on your device and shared with your family through iCloud.")
            }

            Section {
                CreatedByView()
                    .frame(maxWidth: .infinity)
            }
        }
        .sheet(isPresented: $showingOnboarding) {
            OnboardingView()
                .dismissesOnOutsideClick()
        }
    }

    private static var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }
}
