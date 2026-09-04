import SwiftUI
import SwiftData
import ESADesignKit

// The individual blocks of Settings, each one self-contained so the same code
// can be stacked into one scrolling form (iOS) or dealt out across the panes of
// a Settings window (macOS). Every section reads what it needs from the
// environment, so a pane is just a list of the sections that belong in it.

// MARK: - Family

@MainActor
struct FamilySettingsSection: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var context

    var body: some View {
        if let household = appState.currentHousehold {
            Section {
                TextField(String(localized: "Family name"), text: name(household))
                Stepper(value: standardServings(household), in: 1...50) {
                    LabeledContent(
                        String(localized: "Standard portions"),
                        value: String(localized: "\(household.scalingServings) servings")
                    )
                }
            } header: {
                Text(String(localized: "Family"))
            } footer: {
                Text("Recipes are scaled to your standard portions automatically. Everyone in the family shares this setting.")
            }
        }
    }

    private func name(_ household: Household) -> Binding<String> {
        Binding(get: { household.name }, set: { household.name = $0; try? context.save() })
    }

    private func standardServings(_ household: Household) -> Binding<Int> {
        Binding(
            get: { household.scalingServings },
            set: { household.standardServings = max(1, $0); try? context.save() }
        )
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

// MARK: - Plan layout

/// How the plan is laid out, plus — where the meals aren't a pane of their own —
/// the way into the meal editor.
@MainActor
struct PlanSettingsSection: View {
    /// `false` on macOS, where Meals is its own pane in the sidebar.
    var showsMealsLink = true
    /// `nil` where the pane title already says what this is.
    var header: String? = String(localized: "Calendar")

    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var context

    var body: some View {
        if let household = appState.currentHousehold {
            Section {
                Picker(String(localized: "Layout"), selection: style(household)) {
                    ForEach(CalendarStyle.allCases) { style in
                        Text(style.localizedName).tag(style)
                    }
                }
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

    private func style(_ household: Household) -> Binding<CalendarStyle> {
        Binding(get: { household.calendarStyle }, set: { household.calendarStyle = $0; try? context.save() })
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

// MARK: - Shopping

/// Only used where the pantry isn't a pane of its own.
@MainActor
struct ShoppingSettingsSection: View {
    var body: some View {
        Section(String(localized: "Shopping")) {
            NavigationLink {
                PantryStaplesView()
            } label: {
                Label(String(localized: "Pantry staples"), systemImage: "shippingbox")
            }
        }
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
        }
    }

    private static var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }
}
