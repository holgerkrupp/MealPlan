import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// Moving a whole library between builds — in particular out of an Xcode build
/// and into a TestFlight one.
///
/// CloudKit keeps Development and Production records in separate stores, and
/// there is no API that copies private-database records from one to the other:
/// deploying the schema in the CloudKit Console carries the record *types*
/// across, never the rows. So the crossing has to be made through a file, and
/// this screen is both ends of it — write a backup in the build that has the
/// data, restore it in the build that doesn't.
@MainActor
struct DataTransferView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var context

    @State private var includePhotos = true
    @State private var isWriting = false
    @State private var exported: ExportedBackup?
    @State private var showingRestorePicker = false
    @State private var restoring: RestorableBackup?
    @State private var errorMessage: String?

    var body: some View {
        Form {
            environmentSection
            contentsSection
            backupSection
            restoreSection
        }
        .navigationTitle(String(localized: "Data"))
        .formStyle(.grouped)
        .sheet(item: $exported) { BackupShareSheet(backup: $0).dismissesOnOutsideClick() }
        .sheet(item: $restoring) { RestoreBackupSheet(backup: $0).dismissesOnOutsideClick() }
        .fileImporter(
            isPresented: $showingRestorePicker,
            allowedContentTypes: BackupFileType.importableContentTypes
        ) { result in
            switch result {
            case .success(let url):
                Task { await load(url) }
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
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

    private var environmentSection: some View {
        Section {
            LabeledContent(String(localized: "iCloud environment")) {
                Text(BuildEnvironment.cloudKit.localizedName)
                    .foregroundStyle(BuildEnvironment.cloudKit == .unknown ? .secondary : .primary)
            }
            LabeledContent(
                String(localized: "Syncing"),
                value: SharedStore.isMirroringToCloudKit
                    ? String(localized: "On")
                    : String(localized: "This device only")
            )
        } header: {
            Text("iCloud")
        } footer: {
            Text("Development and production are two separate iCloud databases. A build installed from Xcode writes to development; a build from TestFlight or the App Store writes to production, and starts out empty. Nothing copies between them on its own — take a backup here and restore it in the other build.")
        }
    }

    private var contentsSection: some View {
        Section {
            LabeledContent(String(localized: "Dishes"), value: "\(count(Dish.self))")
            LabeledContent(String(localized: "Planned meals"), value: "\(count(MealPlanEntry.self))")
            LabeledContent(String(localized: "Cooked meals"), value: "\(count(CookedLog.self))")
            LabeledContent(String(localized: "Routines"), value: "\(count(MealRoutine.self))")
            LabeledContent(String(localized: "Week templates"), value: "\(count(WeekTemplate.self))")
        } header: {
            Text("On this device")
        } footer: {
            if count(Household.self) > 1 {
                Text("This store holds \(count(Household.self)) family records — two devices each created one before they first synced. Restoring a backup folds them back into a single family.")
            }
        }
    }

    private var backupSection: some View {
        Section {
            Toggle(String(localized: "Include photos"), isOn: $includePhotos)
            Button {
                Task { await createBackup() }
            } label: {
                HStack {
                    Label(String(localized: "Create a backup…"), systemImage: "square.and.arrow.up")
                    if isWriting {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(isWriting)
        } header: {
            Text("Back up")
        } footer: {
            Text("Writes one file holding everything: dishes, ingredients, the plan, routines, cooked history, the shopping list, week templates and your settings. Save it somewhere you can reach from the other build — iCloud Drive or AirDrop.")
        }
    }

    private var restoreSection: some View {
        Section {
            Button(role: .destructive) {
                showingRestorePicker = true
            } label: {
                Label(String(localized: "Restore from a backup…"), systemImage: "square.and.arrow.down")
            }
            .disabled(appState.isGuest)
        } footer: {
            Text(appState.isGuest
                 ? String(localized: "You joined this household as a guest, so you can’t replace its data.")
                 : String(localized: "Replaces everything currently on this device with the contents of the backup. You’ll see what’s in the file before anything is changed."))
        }
    }

    // MARK: - Work

    /// Counted straight off the store rather than through the household's
    /// relationships — the same reason `MealPlanBackup.make` fetches: a dish
    /// whose `household` was never set is still a dish the user can see.
    private func count<T: PersistentModel>(_ type: T.Type) -> Int {
        (try? context.fetchCount(FetchDescriptor<T>())) ?? 0
    }

    private func createBackup() async {
        isWriting = true
        defer { isWriting = false }
        do {
            let backup = try MealPlanBackup.make(from: context, includePhotos: includePhotos)
            let contents = backup.contents
            let staged = try await Task.detached(priority: .userInitiated) { () -> (Data, URL) in
                let data = try MealPlanBackup.encode(backup)
                return (data, try MealPlanBackup.writeTemporaryFile(data, exportedAt: backup.exportedAt))
            }.value
            exported = ExportedBackup(
                url: staged.1,
                data: staged.0,
                baseFilename: MealPlanBackup.baseFilename(for: backup.exportedAt),
                contents: contents
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func load(_ url: URL) async {
        do {
            let backup = try await Task.detached(priority: .userInitiated) {
                try MealPlanBackup.read(fromFileAt: url)
            }.value
            restoring = RestorableBackup(backup: backup)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Handing the file over

struct ExportedBackup: Identifiable {
    let id = UUID()
    /// Staged in the temporary directory, so AirDrop has a named file.
    let url: URL
    /// The same bytes, for the save panel. Only this copy is in memory; the
    /// staged file lives on disk.
    let data: Data
    let baseFilename: String
    let contents: MealPlanBackup.Contents
}

/// Wraps the encoded backup so `fileExporter` can write it wherever the user
/// points. `ShareLink` alone isn't enough: on macOS the share menu offers
/// AirDrop, Mail and Messages but no way to save to a folder.
struct BackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [BackupFileType.contentType] }

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

struct BackupShareSheet: View {
    let backup: ExportedBackup

    @Environment(\.dismiss) private var dismiss
    @State private var showingSavePanel = false
    @State private var savedTo: String?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Image(systemName: "externaldrive.badge.checkmark")
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary)
                Text(String(localized: "Your backup is ready."))
                    .font(.headline)
                Text(BackupSummary.sentence(for: backup.contents))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Text(BackupSummary.fileSize(of: backup.data))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let savedTo {
                    Label(String(localized: "Saved to \(savedTo)"), systemImage: "checkmark.circle.fill")
                        .font(.callout)
                        .foregroundStyle(.green)
                }

                VStack(spacing: 10) {
                    Button {
                        showingSavePanel = true
                    } label: {
                        Label(String(localized: "Save to a folder…"), systemImage: "folder")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)

                    ShareLink(item: backup.url) {
                        Label(String(localized: "Share / AirDrop"), systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                .frame(maxWidth: 320)
            }
            .padding()
            .navigationTitle(String(localized: "Backup"))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Done")) { dismiss() }
                }
            }
            .fileExporter(
                isPresented: $showingSavePanel,
                document: BackupDocument(data: backup.data),
                contentType: BackupFileType.contentType,
                defaultFilename: backup.baseFilename
            ) { result in
                switch result {
                case .success(let url):
                    savedTo = url.deletingLastPathComponent().lastPathComponent
                case .failure(let error):
                    errorMessage = error.localizedDescription
                }
            }
            .alert(
                String(localized: "Couldn’t save the backup"),
                isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
            ) {
                Button(String(localized: "OK"), role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 340)
        #else
        .presentationDetents([.medium])
        #endif
    }
}

enum BackupSummary {
    /// "42 dishes, 180 planned meals, 96 cooked" — only the non-empty parts.
    static func sentence(for contents: MealPlanBackup.Contents) -> String {
        var parts: [String] = []
        if contents.dishes > 0 { parts.append(String(localized: "\(contents.dishes) dishes")) }
        if contents.plannedMeals > 0 { parts.append(String(localized: "\(contents.plannedMeals) planned meals")) }
        if contents.cookedMeals > 0 { parts.append(String(localized: "\(contents.cookedMeals) cooked")) }
        if contents.routines > 0 { parts.append(String(localized: "\(contents.routines) routines")) }
        if contents.weekTemplates > 0 { parts.append(String(localized: "\(contents.weekTemplates) week templates")) }
        if contents.photos > 0 { parts.append(String(localized: "\(contents.photos) photos")) }
        return parts.isEmpty ? String(localized: "Nothing to back up yet.") : parts.joined(separator: ", ")
    }

    static func fileSize(of data: Data) -> String {
        Int64(data.count).formatted(.byteCount(style: .file))
    }
}

#Preview {
    NavigationStack { DataTransferView() }
        .environment(AppState.preview)
        .modelContainer(PreviewData.container)
}
