import SwiftUI
import SwiftData
import ESADesignKit

@MainActor
struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var context

    @AppStorage("search.engine") private var searchEngineRaw = SearchEngine.fallback.rawValue

    @State private var showingOnboarding = false
    @State private var dinnerReminder = MealNotificationScheduler.shared.dinnerEnabled
    @State private var reminderTime: Date = Calendar.current.date(
        bySettingHour: MealNotificationScheduler.shared.dinnerHour, minute: 0, second: 0, of: .now
    ) ?? .now

    var body: some View {
        Form {
            if let household = appState.currentHousehold {
                Section(String(localized: "Family")) {
                    TextField(String(localized: "Family name"), text: bindingName(household))
                }

                Section {
                    Picker(String(localized: "Show amounts in"), selection: bindingUnit(household)) {
                        ForEach(UnitSystem.allCases) { system in
                            Text(system.localizedName).tag(system)
                        }
                    }
                    Toggle(
                        String(localized: "Round scaled and converted amounts"),
                        isOn: bindingRoundedAmounts(household)
                    )
                } header: {
                    Text(String(localized: "Units"))
                } footer: {
                    Text("Uses practical kitchen increments, including whole eggs. Turn off to show exact values.")
                }

                Section(String(localized: "Calendar")) {
                    Picker(String(localized: "Layout"), selection: bindingCalendar(household)) {
                        ForEach(CalendarStyle.allCases) { style in
                            Text(style.localizedName).tag(style)
                        }
                    }
                    NavigationLink {
                        MealsSettingsView()
                    } label: {
                        LabeledContent(String(localized: "Meals"), value: mealsSummary(household))
                    }
                }
            }

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

            Section(String(localized: "Shopping")) {
                NavigationLink {
                    PantryStaplesView()
                } label: {
                    Label(String(localized: "Pantry staples"), systemImage: "shippingbox")
                }
            }

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
                LabeledContent(String(localized: "Version"), value: appVersion)
            } footer: {
                Text("Your plan and dishes are stored on your device and shared with your family through iCloud.")
            }

            Section {
                CreatedByView()
                    .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle(AppSection.settings.title)
        .formStyle(.grouped)
        .sheet(isPresented: $showingOnboarding) {
            OnboardingView()
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

    private func bindingName(_ household: Household) -> Binding<String> {
        Binding(get: { household.name }, set: { household.name = $0; try? context.save() })
    }

    private func bindingUnit(_ household: Household) -> Binding<UnitSystem> {
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

    private func bindingRoundedAmounts(_ household: Household) -> Binding<Bool> {
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

    private func bindingCalendar(_ household: Household) -> Binding<CalendarStyle> {
        Binding(get: { household.calendarStyle }, set: { household.calendarStyle = $0; try? context.save() })
    }

    private func mealsSummary(_ household: Household) -> String {
        let names = household.sortedMealTypes.map(\.name).filter { !$0.isEmpty }
        return names.isEmpty ? String(localized: "None") : names.joined(separator: ", ")
    }

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }
}

#Preview {
    NavigationStack { SettingsView() }
        .environment(AppState.preview)
        .modelContainer(PreviewData.container)
}
