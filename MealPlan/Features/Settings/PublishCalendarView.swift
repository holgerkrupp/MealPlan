import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// Publishing the plan as a subscribable calendar.
///
/// MealPlan has no server, so "publish" doesn't mean MealPlan hosts anything —
/// it means writing a plain `.ics` file somewhere the user controls (iCloud
/// Drive, most naturally) and keeping it current there. Once that file has a
/// public link — which the Files app can create for anything in iCloud
/// Drive — that link *is* the subscribable calendar: Google Calendar, Outlook,
/// an Android phone's stock calendar app, anything that understands "add
/// calendar from URL" can follow along, no MealPlan install required.
@MainActor
struct PublishCalendarView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var context
    @Environment(PublishedCalendarSettings.self) private var settings

    @State private var isWorking = false
    @State private var message: String?
    @State private var errorMessage: String?
    @State private var showingLocationPicker = false
    @State private var pendingDocument: ICSDocument?
    @State private var snapshot: URL?

    var body: some View {
        Form {
            explanationSection
            rangeSection
            statusSection
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
        .fileExporter(
            isPresented: $showingLocationPicker,
            document: pendingDocument,
            contentType: PublishedCalendarFileType.contentType,
            defaultFilename: PublishedCalendarService.suggestedFilename(household: appState.currentHousehold)
        ) { result in
            handleLocationPicked(result)
        }
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
                Text("Anyone with the link can subscribe — in Google Calendar, Outlook, or an Android phone's built-in calendar app — and see the plan without installing MealPlan.")
            } icon: {
                Image(systemName: "calendar.badge.plus")
                    .foregroundStyle(.tint)
            }
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
            Text("Only what's planned in this window is published. It updates automatically as the window rolls forward — no need to republish.")
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        if settings.isPublishing {
            Section {
                LabeledContent(String(localized: "File"), value: settings.filename ?? "—")
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
                    startChoosingLocation()
                } label: {
                    Label(String(localized: "Publish to a different file…"), systemImage: "folder")
                }
                Button(role: .destructive) {
                    settings.stopPublishing()
                    message = String(localized: "Stopped updating the file. The file itself — and any link to it — is untouched.")
                } label: {
                    Label(String(localized: "Stop publishing"), systemImage: "xmark.circle")
                }
            } header: {
                Text("Published")
            } footer: {
                Text("To let someone subscribe: put this file in iCloud Drive, then in the Files app long‑press it and choose Share → “Anyone with the link” → Copy Link. Send them that link. In Google Calendar they add it under “Other calendars → From URL”; on an Android phone, the same link works in most calendar apps' “subscribe” option.")
            }
        } else {
            Section {
                Button {
                    startChoosingLocation()
                } label: {
                    HStack {
                        Label(String(localized: "Choose where to publish…"), systemImage: "square.and.arrow.up")
                        if isWorking {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
            } footer: {
                Text("Pick a spot in iCloud Drive. MealPlan keeps the file there up to date as the plan changes; you turn it into a shareable link from the Files app.")
            }
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
            Text("Sends a one-time snapshot of the same window over AirDrop, Mail or Messages. It won't stay in sync — for that, publish above.")
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

    private func startChoosingLocation() {
        do {
            let data = try PublishedCalendarService.makeData(
                household: appState.currentHousehold, settings: settings, context: context
            )
            pendingDocument = ICSDocument(data: data)
            showingLocationPicker = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func handleLocationPicked(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            guard let data = pendingDocument?.data else { return }
            do {
                try PublishedCalendarService.confirmPublished(at: url, data: data, settings: settings)
                message = String(localized: "Published. Create a public link to this file from the Files app to let others subscribe.")
            } catch {
                errorMessage = error.localizedDescription
            }
        case .failure(let error):
            errorMessage = error.localizedDescription
        }
        pendingDocument = nil
    }

    private func updateNow(silently: Bool = false) async {
        guard settings.isPublishing else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try PublishedCalendarService.refresh(household: appState.currentHousehold, settings: settings, context: context)
            if !silently { message = String(localized: "Up to date.") }
        } catch {
            errorMessage = error.localizedDescription
        }
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

/// Wraps the encoded feed so `.fileExporter` can write it wherever the user
/// points, the same way `BackupDocument` does for the whole-store backup.
struct ICSDocument: FileDocument {
    static var readableContentTypes: [UTType] { [PublishedCalendarFileType.contentType] }

    let data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        guard let contents = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        data = contents
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

#Preview {
    NavigationStack { PublishCalendarView() }
        .environment(AppState.preview)
        .environment(PublishedCalendarSettings())
        .modelContainer(PreviewData.container)
}
