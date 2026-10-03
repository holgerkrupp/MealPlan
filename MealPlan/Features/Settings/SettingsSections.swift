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
            .detailPresentation(isPresented: $showingPaywall, route: .unlock) {
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
                Picker(String(localized: "Show amounts in"), selection: unitPresentation(household)) {
                    ForEach(UnitPresentationOverride.allCases) { setting in
                        Text(setting.localizedName).tag(setting)
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

    private func unitPresentation(_ household: Household) -> Binding<UnitPresentationOverride> {
        Binding(
            get: { household.unitPresentationOverride },
            set: { value in
                household.unitPresentationOverride = value
                ShoppingListBuilder.refreshDisplayText(
                    for: household.shoppingItems ?? [],
                    system: household.presentationUnitSystem,
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
                    system: household.presentationUnitSystem,
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

@MainActor
struct LeftoverSuggestionsSettingsSection: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var context

    var body: some View {
        if let household = appState.currentHousehold {
            Section {
                Toggle("Suggest ways to use likely leftovers", isOn: enabled(household))
                NavigationLink {
                    TypicalPackageSizesView()
                } label: {
                    Label("Typical package sizes", systemImage: "shippingbox")
                }
            } header: {
                Text("Leftover suggestions")
            } footer: {
                Text("Optional suggestions use typical regional package sizes. They never change recipes, shopping quantities or your plan.")
            }
        }
    }

    private func enabled(_ household: Household) -> Binding<Bool> {
        return Binding(get: { household.leftoverSuggestionsEnabled }, set: { household.leftoverSuggestionsEnabled = $0; try? context.save() })
    }
}

// MARK: - Fridge Experience

@MainActor
struct FridgeExperienceSettingsSection: View {
    @AppStorage(FridgeExperienceSettings.enabledKey) private var enabled = false
    @AppStorage(FridgeExperienceSettings.simulatedFoldableKey) private var simulatedFoldable = false
    @AppStorage(FridgeExperienceSettings.simulatedPostureKey) private var simulatedPosture = FoldingPosture.closed.rawValue

    private var simulatedPostureBinding: Binding<FoldingPosture> {
        Binding(
            get: { FoldingPosture(rawValue: simulatedPosture) ?? .closed },
            set: { simulatedPosture = $0.rawValue }
        )
    }

    var body: some View {
        if FridgeExperienceSettings.isPhoneInterface {
            Section {
                Toggle(String(localized: "Fridge Experience"), isOn: $enabled)
                if enabled {
                    NavigationLink {
                        FridgeExperienceView()
                    } label: {
                        Label(String(localized: "Open Fridge"), systemImage: "refrigerator")
                    }
                    #if DEBUG
                    Toggle(String(localized: "Simulate Duo hardware"), isOn: $simulatedFoldable)
                    if simulatedFoldable {
                        Picker(String(localized: "Preview posture"), selection: simulatedPostureBinding) {
                            ForEach([FoldingPosture.closed, .partiallyOpen, .open], id: \.self) { posture in
                                Text(posture.localizedName).tag(posture)
                            }
                        }
                    }
                    #endif
                    if !FoldingDeviceStateProvider.current.isFoldable && !simulatedFoldable {
                        Label(String(localized: "Foldable hardware not detected. MealPlan stays in its standard interface."), systemImage: "info.circle")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Label(String(localized: "Fridge is available as an optional tab. The standard MealPlan tabs remain available."), systemImage: "checkmark.circle")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text(String(localized: "Experimental"))
            } footer: {
                Text(String(localized: "Fridge is a playful presentation of the existing plan, shopping list and ingredient inventory. It never replaces or creates a second source of truth."))
            }
        }
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

/// External services and system hand-offs live in one predictable place. Each
/// row shows its state before opening the detailed controls.
@MainActor
struct ConnectionsSettingsSection: View {
    @Environment(AppState.self) private var appState
    @Environment(CalendarContextStore.self) private var calendarStore
    @Environment(PublishedCalendarSettings.self) private var publishedCalendarSettings

    var body: some View {
        Section {
            NavigationLink {
                Form { CalendarIntegrationSection() }
                    .formStyle(.grouped)
                    .navigationTitle(String(localized: "Calendar"))
            } label: {
                LabeledContent {
                    Text(calendarStatus)
                } label: {
                    Label(String(localized: "Calendar"), systemImage: "calendar.badge.clock")
                }
            }

            NavigationLink {
                PublishCalendarView()
            } label: {
                LabeledContent {
                    Text(publishedCalendarSettings.isPublishing
                         ? String(localized: "Published") : String(localized: "Not published"))
                } label: {
                    Label(String(localized: "Publish Calendar"), systemImage: "square.and.arrow.up.on.square")
                }
            }

            NavigationLink {
                Form { RemindersSettingsSection() }
                    .formStyle(.grouped)
                    .navigationTitle(String(localized: "Reminders"))
            } label: {
                LabeledContent {
                    Text(MealNotificationScheduler.shared.dinnerEnabled
                         ? String(localized: "On") : String(localized: "Off"))
                } label: {
                    Label(String(localized: "Reminders"), systemImage: "bell")
                }
            }

            NavigationLink {
                BringSettingsView()
            } label: {
                LabeledContent {
                    Text(bringStatus)
                } label: {
                    Label(String(localized: "Bring!"), systemImage: "cart")
                }
            }

            NavigationLink {
                SiriPhrasesView()
            } label: {
                Label(String(localized: "Siri & Shortcuts"), systemImage: "waveform")
            }
        } header: {
            Text(String(localized: "Connections"))
        } footer: {
            Text(String(localized: "See what is connected, then open only the service you want to change."))
        }
    }

    private var calendarStatus: String {
        if calendarStore.isActive { return String(localized: "Connected") }
        if calendarStore.settings.isEnabled { return String(localized: "Needs attention") }
        return String(localized: "Not connected")
    }

    private var bringStatus: String {
        guard BringSyncService.shared.hasAccount,
              let name = appState.currentHousehold?.bringListName,
              appState.currentHousehold?.isConnectedToBring == true
        else { return String(localized: "Not connected") }
        return name
    }
}

// MARK: - Siri

/// The phrases exposed through App Intents. Keep this page close to the
/// registered shortcuts so people can discover the wording Siri understands.
@MainActor
struct SiriPhrasesView: View {
    var body: some View {
        Form {
            Section {
                Text("You can say these phrases to Siri. Siri asks for the dish, day, or meal when a detail is missing.")
            }

            Section("Plan meals") {
                phraseRow(
                    "Hey Siri, put pizza in meals in Meals",
                    detail: "Plans a saved dish for a chosen day and meal."
                )
                phraseRow(
                    "Hey Siri, put a dish in meals in Meals",
                    detail: "Lets Siri collect the dish, day, and meal, and creates the dish if needed."
                )
                phraseRow(
                    "Hey Siri, plan a meal in Meals",
                    detail: "Plans a saved dish after Siri asks for the missing details."
                )
                phraseRow(
                    "Hey Siri, add a dish to the plan in Meals",
                    detail: "Another way to start planning a saved dish."
                )
                phraseRow(
                    "Hey Siri, add a dish to the meal plan in Meals",
                    detail: "Starts planning a dish and asks for any missing details."
                )
            }

            Section("Add dishes") {
                phraseRow(
                    "Hey Siri, add a dish to Meals",
                    detail: "Creates a new dish in your library."
                )
                phraseRow(
                    "Hey Siri, new dish in Meals",
                    detail: "Creates a new dish in your library."
                )
            }

            Section("Ask about your plan") {
                phraseRow(
                    "Hey Siri, what is planned today in Meals",
                    detail: "Reads today's planned meals aloud."
                )
                phraseRow(
                    "Hey Siri, what are we eating today in Meals",
                    detail: "Another way to ask what is planned today."
                )
                phraseRow(
                    "Hey Siri, show this week's plan in Meals",
                    detail: "Reads the current week's plan aloud."
                )
                phraseRow(
                    "Hey Siri, what are we eating this week in Meals",
                    detail: "Another way to ask about this week's plan."
                )
            }

            Section("Shopping") {
                phraseRow("Hey Siri, add milk to my shopping list in Meals", detail: "Adds an item and optional amount to the shared shopping list.")
                phraseRow("Hey Siri, what do I need to buy in Meals", detail: "Reads the current shopping list, with unchecked items first.")
                phraseRow("Hey Siri, mark milk as bought in Meals", detail: "Completes a matching shopping item for everyone in the household.")
                phraseRow("Hey Siri, put tomatoes back on the list in Meals", detail: "Reopens a completed shopping item.")
            }

            Section("Recipes and cooking") {
                phraseRow("Hey Siri, find a recipe with chicken in Meals", detail: "Searches saved dishes by name, ingredient, category, and tags.")
                phraseRow("Hey Siri, open the chicken recipe in Meals", detail: "Opens the matching dish in MealPlan.")
                phraseRow("Hey Siri, start cooking chicken curry in Meals", detail: "Starts cooking mode for a saved dish.")
                phraseRow("Hey Siri, what is the current cooking step in Meals", detail: "Reads the active cooking step and progress.")
                phraseRow("Hey Siri, start a ten minute timer in Meals", detail: "Starts, pauses, resumes, cancels, or finishes a cooking timer.")
            }

            Section("Pantry and inventory") {
                phraseRow("Hey Siri, we have six eggs in Meals", detail: "Sets the pantry quantity for an ingredient.")
                phraseRow("Hey Siri, we are out of olive oil in Meals", detail: "Marks an ingredient as out of stock.")
                phraseRow("Hey Siri, what am I running low on in Meals", detail: "Lists low and out-of-stock ingredients.")
                phraseRow("Hey Siri, what expires soon in Meals", detail: "Lists ingredients approaching their best-before date.")
                phraseRow("Hey Siri, add out of stock ingredients to my shopping list in Meals", detail: "Adds low or out-of-stock ingredients without duplicating existing items.")
            }

            Section("Routines and templates") {
                phraseRow("Hey Siri, what meal routines do we have in Meals", detail: "Lists saved recurring meal routines.")
                phraseRow("Hey Siri, pause Taco Tuesday in Meals", detail: "Pauses a routine without deleting it.")
                phraseRow("Hey Siri, resume Taco Tuesday in Meals", detail: "Resumes a paused routine.")
                phraseRow("Hey Siri, apply the holiday week template in Meals", detail: "Applies a saved week template, optionally replacing the selected range.")
            }

            Section("Leftovers and nutrition") {
                phraseRow("Hey Siri, what leftovers will we have this week in Meals", detail: "Estimates leftovers from planned servings and household size.")
                phraseRow("Hey Siri, what can I cook with leftovers in Meals", detail: "Suggests saved dishes using likely leftover ingredients.")
                phraseRow("Hey Siri, how much protein is in today's plan in Meals", detail: "Reports estimated nutrition for a day, week, or selected range.")
            }

            Section("Shortcuts") {
                Text("The same actions are available in the Shortcuts app, where you can combine them with reminders, timers, and automations.")
                phraseRow("Shopping List", detail: "Get, add, complete, reopen, remove, clear, or regenerate shopping items.")
                phraseRow("Recipes", detail: "Search and open saved dishes.")
                phraseRow("Cooking", detail: "Start cooking, navigate steps, and control timers.")
                phraseRow("Pantry", detail: "Update inventory and find low or expiring ingredients.")
                phraseRow("Routines and nutrition", detail: "Manage routines and templates, inspect leftovers, and read nutrition estimates.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle(String(localized: "Siri & Shortcuts"))
    }

    private func phraseRow(_ phrase: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(phrase)
            Text(detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
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
    /// Set once the tips have been brought back, so the button can say so
    /// instead of silently doing nothing on a second tap.
    @State private var tipsWereReset = false

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
                Button {
                    Task {
                        await MealPlanTips.resetEligibility()
                        tipsWereReset = true
                    }
                } label: {
                    Label(
                        tipsWereReset ? String(localized: "Tips Will Show Again") : String(localized: "Show Tips Again"),
                        systemImage: tipsWereReset ? "checkmark" : "lightbulb"
                    )
                }
                .disabled(tipsWereReset)
            } footer: {
                Text("Brings back the tips about moving meals, grouping dishes, and cooking hands-free, one at a time as you use the app.")
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
        .detailPresentation(isPresented: $showingOnboarding, route: .gettingStarted) {
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
