import SwiftUI
import SwiftData

/// Publishing the plan into a calendar.
///
/// MealPlan has no server, so "publish" means writing straight into a
/// calendar the user already has — their own iCloud calendar, a shared family
/// one, or a Google or Outlook calendar added as an account on this device.
/// That last case is the point: once the plan is mirrored into a calendar a
/// Google or Microsoft account already syncs, anyone on that account — an
/// Android phone included — sees it in their own calendar app, no MealPlan
/// install required.
@MainActor
struct PublishCalendarView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var context
    @Environment(PublishedCalendarSettings.self) private var settings
    @Environment(\.calendarEventWriter) private var writer

    @State private var authorization: CalendarAuthorization = .notDetermined
    @State private var availableCalendars: [MealCalendarInfo] = []
    @State private var isWorking = false
    @State private var isChoosingCalendar = false
    @State private var message: String?
    @State private var errorMessage: String?
    @State private var snapshot: URL?

    var body: some View {
        Form {
            explanationSection
            if settings.isPublishing, !isChoosingCalendar {
                statusSection
                rangeSection
            } else {
                calendarPickerSection
            }
            shareCopySection
            if let message {
                Section {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(String(localized: "Publish Calendar"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .disabled(isWorking)
        .task { await refreshAuthorizationAndCalendars() }
        .alert(
            String(localized: "Something went wrong"),
            isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
        ) {
            Button(String(localized: "OK"), role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - Sections

    private var explanationSection: some View {
        Section {
            Label {
                Text("Writes the plan into a calendar you pick. If that calendar is a Google or Outlook one added to this device, anyone signed into it — Android included — sees it in their own calendar app.")
            } icon: {
                Image(systemName: "calendar.badge.plus")
                    .foregroundStyle(.tint)
            }
        }
    }

    @ViewBuilder
    private var calendarPickerSection: some View {
        switch authorization {
        case .fullAccess, .writeOnly:
            Section {
                if availableCalendars.isEmpty {
                    Text("No calendar on this device accepts new events. Add or unlock one in the Calendar app, then come back here.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(availableCalendars) { calendar in
                        Button {
                            Task { await choose(calendar) }
                        } label: {
                            HStack {
                                CalendarColorDot(color: calendar.color)
                                VStack(alignment: .leading) {
                                    Text(calendar.title)
                                        .foregroundStyle(.primary)
                                    if !calendar.sourceTitle.isEmpty {
                                        Text(calendar.sourceTitle)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if calendar.id == settings.destinationCalendarID {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.tint)
                                }
                            }
                        }
                    }
                }
                if isChoosingCalendar {
                    Button(String(localized: "Cancel")) { isChoosingCalendar = false }
                }
            } header: {
                Text("Choose a calendar")
            } footer: {
                Text("Only calendars that accept new events are listed. A calendar backed by a Google or Outlook account works best for sharing outside MealPlan.")
            }
        case .notDetermined:
            Section {
                Button {
                    Task { await requestAccess() }
                } label: {
                    HStack {
                        Label(String(localized: "Allow Calendar access"), systemImage: "calendar.badge.plus")
                        if isWorking {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
            } footer: {
                Text("MealPlan needs permission to add events before it can publish the plan.")
            }
        case .denied, .restricted, .unknown:
            Section {
                Text("Calendar access is off for MealPlan. Turn it on in Settings to publish the plan.")
                    .foregroundStyle(.secondary)
                if let url = CalendarSystemSettings.url {
                    Link(String(localized: "Open Settings"), destination: url)
                }
            }
        }
    }

    private var statusSection: some View {
        Section {
            LabeledContent(String(localized: "Calendar"), value: settings.destinationCalendarTitle ?? "—")
            if let lastPublishedAt = settings.lastPublishedAt {
                LabeledContent(String(localized: "Last updated"), value: lastPublishedAt.formatted(.relative(presentation: .named)))
            }
            Button {
                Task { await updateNow() }
            } label: {
                HStack {
                    Label(String(localized: "Update now"), systemImage: "arrow.clockwise")
                    if isWorking {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            Button {
                isChoosingCalendar = true
                Task { await refreshAuthorizationAndCalendars() }
            } label: {
                Label(String(localized: "Publish to a different calendar…"), systemImage: "calendar")
            }
            Button(role: .destructive) {
                Task { await stopPublishing() }
            } label: {
                Label(String(localized: "Stop publishing"), systemImage: "xmark.circle")
            }
        } header: {
            Text("Published")
        } footer: {
            Text("The plan's events are kept up to date in that calendar automatically. Stopping removes only the events MealPlan added — nothing else in the calendar is touched.")
        }
    }

    private var rangeSection: some View {
        Section {
            Picker(String(localized: "Includes"), selection: rangeBinding) {
                ForEach(PublishedCalendarRange.allCases) { range in
                    Text(range.localizedName).tag(range)
                }
            }
        } footer: {
            Text("Only what's planned in this window is published. It updates automatically as the window rolls forward.")
        }
    }

    private var shareCopySection: some View {
        Section {
            if let snapshot {
                ShareLink(item: snapshot) {
                    Label(String(localized: "Share a copy…"), systemImage: "square.and.arrow.up.on.square")
                }
            } else {
                Button {
                    Task { await shareSnapshot() }
                } label: {
                    HStack {
                        Label(String(localized: "Prepare a copy to share…"), systemImage: "square.and.arrow.up.on.square")
                        if isWorking {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
            }
        } footer: {
            Text("Sends a one-time .ics snapshot of the same window over AirDrop, Mail or Messages. It won't stay in sync — for that, publish into a calendar above.")
        }
    }

    // MARK: - Bindings

    private var rangeBinding: Binding<PublishedCalendarRange> {
        Binding(
            get: { settings.range },
            set: { newValue in
                settings.range = newValue
                Task { await updateNow(silently: true) }
            }
        )
    }

    // MARK: - Actions

    private func refreshAuthorizationAndCalendars() async {
        authorization = await writer.authorization()
        guard authorization.canWrite else { return }
        do {
            availableCalendars = try await writer.writableCalendars()
        } catch {
            availableCalendars = []
        }
    }

    private func requestAccess() async {
        isWorking = true
        defer { isWorking = false }
        authorization = await writer.requestAccess()
        await refreshAuthorizationAndCalendars()
    }

    private func choose(_ calendar: MealCalendarInfo) async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await PublishedCalendarService.publish(
                calendarID: calendar.id,
                calendarTitle: calendar.title,
                household: appState.currentHousehold,
                settings: settings,
                context: context,
                writer: writer
            )
            isChoosingCalendar = false
            message = String(localized: "Published to “\(calendar.title)”.")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func updateNow(silently: Bool = false) async {
        guard settings.isPublishing else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try await PublishedCalendarService.refresh(
                household: appState.currentHousehold, settings: settings, context: context, writer: writer
            )
            if !silently { message = String(localized: "Up to date.") }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func stopPublishing() async {
        isWorking = true
        defer { isWorking = false }
        await PublishedCalendarService.stopPublishing(settings: settings, writer: writer)
        message = String(localized: "Stopped publishing. The events MealPlan added were removed.")
    }

    private func shareSnapshot() async {
        isWorking = true
        defer { isWorking = false }
        do {
            snapshot = try PublishedCalendarService.makeSnapshotFile(
                household: appState.currentHousehold, settings: settings, context: context
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

#Preview {
    NavigationStack { PublishCalendarView() }
        .environment(AppState.preview)
        .environment(PublishedCalendarSettings())
        .modelContainer(PreviewData.container)
}
