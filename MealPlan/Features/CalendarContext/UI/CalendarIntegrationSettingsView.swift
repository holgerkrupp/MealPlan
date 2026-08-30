import SwiftUI
import SwiftData

/// Which calendars take part, how much of them may be shown, and (optionally)
/// who they belong to.
@MainActor
struct CalendarIntegrationSettingsView: View {
    @Environment(CalendarContextStore.self) private var store: CalendarContextStore?
    @Environment(\.openURL) private var openURL
    @Query(sort: [SortDescriptor(\HouseholdMember.name)]) private var members: [HouseholdMember]

    var body: some View {
        Form {
            if let store {
                content(store)
            } else {
                Text("Calendar integration isn’t available.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(String(localized: "Calendar options"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task {
            await store?.loadAvailableCalendars()
        }
    }

    @ViewBuilder
    private func content(_ store: CalendarContextStore) -> some View {
        if store.authorization.canReadEvents {
            calendarSection(store)
            privacySection(store)
            timingSection
            peopleSection(store)

            Section {
                Text("These choices stay on this device and are never shared with your family or iCloud. MealPlan only reads your calendars — it never adds, changes or deletes events.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            Section {
                Text(store.authorization.localizedExplanation ?? "")
                    .foregroundStyle(.secondary)
                if store.authorization.needsSystemSettings, let url = CalendarSystemSettings.url {
                    Button {
                        openURL(url)
                    } label: {
                        Label(String(localized: "Open Settings"), systemImage: "gear")
                    }
                }
            } header: {
                Text("Calendar access")
            }
        }
    }

    // MARK: - Calendars

    @ViewBuilder
    private func calendarSection(_ store: CalendarContextStore) -> some View {
        Section {
            if store.availableCalendars.isEmpty {
                Text(store.isLoadingCalendars
                     ? String(localized: "Looking for calendars…")
                     : String(localized: "No calendars found."))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(store.availableCalendars) { calendar in
                    Toggle(isOn: selectionBinding(store, calendar: calendar)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(calendar.title)
                            if !calendar.sourceTitle.isEmpty {
                                Text(calendar.sourceTitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                HStack {
                    Button(String(localized: "Select all")) {
                        store.settings.selectAll(store.availableCalendars)
                        store.settingsChanged()
                    }
                    Spacer()
                    Button(String(localized: "Select none")) {
                        store.settings.selectNone()
                        store.settingsChanged()
                    }
                }
                .buttonStyle(.borderless)
            }
        } header: {
            Text("Calendars used for meal planning")
        } footer: {
            Text("Nothing is used until you pick a calendar here. New calendars are never added on their own.")
        }
    }

    private func selectionBinding(_ store: CalendarContextStore, calendar: MealCalendarInfo) -> Binding<Bool> {
        Binding(
            get: { store.settings.isSelected(calendar.id) },
            set: { isOn in
                store.settings.setSelected(isOn, for: calendar.id)
                store.settingsChanged()
            }
        )
    }

    // MARK: - Privacy

    @ViewBuilder
    private func privacySection(_ store: CalendarContextStore) -> some View {
        Section {
            Picker(String(localized: "Calendar detail"), selection: privacyBinding(store)) {
                ForEach(CalendarPrivacyMode.allCases) { mode in
                    Text(mode.localizedName).tag(mode)
                }
            }
            Text(store.settings.privacyMode.localizedDescription)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } header: {
            Text("Privacy")
        } footer: {
            Text("Event notes, invitees, locations and links are never read, shown or stored.")
        }
    }

    private func privacyBinding(_ store: CalendarContextStore) -> Binding<CalendarPrivacyMode> {
        Binding(
            get: { store.settings.privacyMode },
            set: { mode in
                store.settings.privacyMode = mode
                store.settingsChanged()
            }
        )
    }

    // MARK: - Meal timing

    @ViewBuilder
    private var timingSection: some View {
        Section {
            NavigationLink {
                MealTimingSettingsView()
            } label: {
                Label(String(localized: "Meal times"), systemImage: "clock")
            }
        } footer: {
            Text("Only events near a meal’s time are considered, so a day’s full calendar never lands in your plan.")
        }
    }

    // MARK: - People (optional)

    @ViewBuilder
    private func peopleSection(_ store: CalendarContextStore) -> some View {
        let selected = store.availableCalendars.filter { store.settings.isSelected($0.id) }
        if !members.isEmpty && !selected.isEmpty {
            Section {
                ForEach(selected) { calendar in
                    Picker(calendar.title, selection: ownerBinding(store, calendarID: calendar.id)) {
                        Text(String(localized: "Nobody")).tag("")
                        ForEach(memberNames, id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                }
            } header: {
                Text("Whose calendar is this?")
            } footer: {
                Text("Optional. When you say who a calendar belongs to, the plan can show who is still busy around a meal. MealPlan never guesses this from calendar names.")
            }
        }
    }

    private var memberNames: [String] {
        Array(Set(members.map(\.name).filter { !$0.isEmpty })).sorted()
    }

    private func ownerBinding(_ store: CalendarContextStore, calendarID: String) -> Binding<String> {
        Binding(
            get: { store.settings.owner(of: calendarID) ?? "" },
            set: { name in
                store.settings.setOwner(name.isEmpty ? nil : name, for: calendarID)
            }
        )
    }
}
