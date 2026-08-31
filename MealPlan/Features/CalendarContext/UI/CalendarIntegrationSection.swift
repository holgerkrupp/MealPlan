import SwiftUI

/// The "Calendar integration" block on the Settings screen: the switch itself,
/// plus whatever the current permission state needs the user to know.
///
/// Nothing here touches EventKit — it talks to `CalendarContextStore` only.
@MainActor
struct CalendarIntegrationSection: View {
    @Environment(CalendarContextStore.self) private var store: CalendarContextStore?
    @Environment(\.openURL) private var openURL
    @State private var isRequesting = false

    var body: some View {
        if let store {
            content(store)
        }
    }

    @ViewBuilder
    private func content(_ store: CalendarContextStore) -> some View {
        Section {
            Toggle(String(localized: "Use Calendar for meal planning"), isOn: enabledBinding(store))

            if store.settings.isEnabled {
                switch store.authorization {
                case .fullAccess:
                    NavigationLink {
                        CalendarIntegrationSettingsView()
                    } label: {
                        LabeledContent(
                            String(localized: "Calendar options"),
                            value: summary(store)
                        )
                    }
                case .notDetermined:
                    permissionPrimer(store)
                case .denied, .restricted, .writeOnly, .unknown:
                    unavailableExplanation(store)
                }
            }
        } header: {
            Text("Calendar integration")
        } footer: {
            Text("Use events from selected calendars to provide helpful context when planning meals.")
        }
    }

    /// Explains the access *before* Apple's dialog can appear.
    @ViewBuilder
    private func permissionPrimer(_ store: CalendarContextStore) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("MealPlan needs permission to read your calendars. It shows only whether people are busy around a meal — and never changes, adds or deletes anything in Calendar.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                isRequesting = true
                Task {
                    await store.requestCalendarAccess()
                    isRequesting = false
                }
            } label: {
                Label(String(localized: "Allow Calendar access"), systemImage: "calendar.badge.checkmark")
            }
            .disabled(isRequesting)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func unavailableExplanation(_ store: CalendarContextStore) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(store.authorization.localizedExplanation ?? "")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            }
            if store.authorization.needsSystemSettings, let url = CalendarSystemSettings.url {
                Button {
                    openURL(url)
                } label: {
                    Label(String(localized: "Open Settings"), systemImage: "gear")
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private func enabledBinding(_ store: CalendarContextStore) -> Binding<Bool> {
        Binding(
            get: { store.settings.isEnabled },
            set: { isOn in
                if isOn {
                    Task { await store.enableIntegration() }
                } else {
                    store.disableIntegration()
                }
            }
        )
    }

    private func summary(_ store: CalendarContextStore) -> String {
        let count = store.settings.selectedCalendarIdentifiers.count
        guard count > 0 else { return String(localized: "Choose calendars") }
        let calendars = count == 1
            ? String(localized: "1 calendar")
            : String(localized: "\(count) calendars")
        return "\(calendars) · \(store.settings.privacyMode.localizedName)"
    }
}
