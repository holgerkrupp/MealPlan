import SwiftUI
import SwiftData
import ESADesignKit

/// App preferences.
///
/// macOS gets the System Settings layout — a sidebar of panes next to a grouped
/// form — because the Settings window is shared with the rest of the system and
/// people navigate it by muscle memory. Everywhere else the same sections stack
/// into one scrolling form.
///
/// The sections themselves live in `SettingsSections.swift`; a pane is only a
/// list of the ones that belong together.
@MainActor
struct SettingsView: View {
    /// How the sections are arranged.
    enum Layout {
        /// One scrolling form — iOS, and the macOS main window's fallback.
        case stacked
        #if os(macOS)
        /// Sidebar of panes beside a grouped form — the macOS Settings window.
        case panes
        #endif
    }

    #if os(macOS)
    var layout: Layout = .panes
    #else
    var layout: Layout = .stacked
    #endif

    #if os(macOS)
    @State private var pane: SettingsPane = .general
    #endif

    var body: some View {
        switch layout {
        case .stacked:
            stacked
        #if os(macOS)
        case .panes:
            paned
        #endif
        }
    }

    // MARK: - Stacked

    private var stacked: some View {
        Form {
            UnlockSettingsSection()
            HouseholdSettingsSection()
            UnitsSettingsSection()
            PlanSettingsSection()
            CalendarIntegrationSection()
            RecipeSearchSettingsSection()
            RemindersSettingsSection()
            BringSettingsSection()
            DataSettingsSection()
            AboutSettingsSection()
        }
        .navigationTitle(AppSection.settings.title)
        .formStyle(.grouped)
    }

    // MARK: - Panes

    #if os(macOS)
    private var paned: some View {
        NavigationSplitView {
            List(SettingsPane.allCases, selection: $pane) { pane in
                Label {
                    Text(pane.title)
                } icon: {
                    SettingsPaneIcon(pane: pane)
                }
                .tag(pane)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 205, max: 240)
        } detail: {
            NavigationStack {
                detail(pane)
                    .navigationTitle(pane.title)
            }
        }
        .frame(width: 760, height: 520)
    }

    /// Panes that are wholly one existing screen show it directly; the rest are
    /// a grouped form of sections.
    @ViewBuilder
    private func detail(_ pane: SettingsPane) -> some View {
        switch pane {
        case .general:
            paneForm {
                UnlockSettingsSection()
                UnitsSettingsSection()
                RecipeSearchSettingsSection()
            }
        case .household:
            HouseholdSettingsView()
        case .plan:
            paneForm {
                PlanSettingsSection(showsMealsLink: false, header: nil)
                RemindersSettingsSection()
            }
        case .meals:
            MealsSettingsView()
        case .calendar:
            paneForm {
                CalendarIntegrationSection()
            }
        case .shopping:
            BringSettingsView()
        case .data:
            DataTransferView()
        case .about:
            paneForm {
                AboutSettingsSection()
            }
        }
    }

    private func paneForm<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        Form(content: content)
            .formStyle(.grouped)
    }
    #endif
}

#if os(macOS)

/// The panes in the sidebar, in the order they appear.
enum SettingsPane: String, CaseIterable, Identifiable {
    case general
    case household
    case plan
    case meals
    case calendar
    case shopping
    case data
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: String(localized: "General")
        case .household: String(localized: "Household")
        case .plan: String(localized: "Plan")
        case .meals: String(localized: "Meals")
        case .calendar: String(localized: "Calendar")
        case .shopping: String(localized: "Shopping")
        case .data: String(localized: "Data")
        case .about: String(localized: "About")
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .household: "person.2"
        case .plan: "calendar"
        case .meals: "fork.knife"
        case .calendar: "calendar.badge.clock"
        case .shopping: "cart"
        case .data: "externaldrive"
        case .about: "info.circle"
        }
    }

    var tint: Color {
        switch self {
        case .general: .gray
        case .household: .purple
        case .plan: .blue
        case .meals: .orange
        case .calendar: .red
        case .shopping: .green
        case .data: .indigo
        case .about: .teal
        }
    }
}

/// The tinted rounded square System Settings uses for sidebar rows.
private struct SettingsPaneIcon: View {
    let pane: SettingsPane

    var body: some View {
        Image(systemName: pane.symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 20, height: 20)
            .background(pane.tint.gradient, in: .rect(cornerRadius: 5))
    }
}

#endif

#Preview("Stacked") {
    NavigationStack { SettingsView(layout: .stacked) }
        .environment(AppState.preview)
        .environment(PurchaseManager.shared)
        .modelContainer(PreviewData.container)
}

#if os(macOS)
#Preview("Settings window") {
    SettingsView()
        .environment(AppState.preview)
        .environment(PurchaseManager.shared)
        .modelContainer(PreviewData.container)
}
#endif
