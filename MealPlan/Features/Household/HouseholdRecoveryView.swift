import SwiftUI
import SwiftData

/// A deliberate, user-facing way to choose an exact iCloud household. This is
/// separate from launch bootstrap because recovery must never silently prefer
/// a shared or older zone over another plausible household.
@MainActor
struct HouseholdRecoveryView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var context

    @State private var households: [HouseholdRecoveryCandidate] = []
    @State private var recentlyDeleted: [HouseholdRecoveryCandidate] = []
    @State private var safetyBackups: [HouseholdSafetyBackup] = []
    @State private var isLoading = true
    @State private var isWorking = false
    @State private var progress: HouseholdCloudDownloadProgress?
    @State private var pendingAction: RecoveryAction?
    @State private var errorMessage: String?
    @State private var completionMessage: String?
    @State private var showsDiagnostics = false

    private enum RecoveryAction: Identifiable {
        case restore(HouseholdRecoveryCandidate)
        case restoreSafetyBackup(HouseholdSafetyBackup)
        case moveToRecentlyDeleted(HouseholdRecoveryCandidate)
        case purge(HouseholdRecoveryCandidate)

        var id: String {
            switch self {
            case .restore(let candidate): "restore-\(candidate.id)"
            case .restoreSafetyBackup(let backup): "safety-\(backup.id.path)"
            case .moveToRecentlyDeleted(let candidate): "delete-\(candidate.id)"
            case .purge(let candidate): "purge-\(candidate.id)"
            }
        }

        var title: String {
            switch self {
            case .restore: String(localized: "Restore this household on this device?")
            case .restoreSafetyBackup: String(localized: "Restore this local safety backup?")
            case .moveToRecentlyDeleted: String(localized: "Move this household to Recently Deleted?")
            case .purge: String(localized: "Permanently delete this household?")
            }
        }
    }

    var body: some View {
        Group {
            if isLoading {
                ProgressView(String(localized: "Looking for iCloud households…"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                list
            }
        }
        .navigationTitle(String(localized: "Household Recovery"))
        .task { await refresh() }
        .confirmationDialog(
            pendingAction?.title ?? "",
            isPresented: Binding(get: { pendingAction != nil }, set: { if !$0 { pendingAction = nil } }),
            titleVisibility: .visible,
            presenting: pendingAction
        ) { action in
            switch action {
            case .restore:
                Button(String(localized: "Restore on This Device"), role: .destructive) {
                    Task { await perform(action) }
                }
            case .restoreSafetyBackup:
                Button(String(localized: "Restore Safety Backup"), role: .destructive) {
                    Task { await perform(action) }
                }
            case .moveToRecentlyDeleted:
                Button(String(localized: "Move to Recently Deleted"), role: .destructive) {
                    Task { await perform(action) }
                }
            case .purge:
                Button(String(localized: "Permanently Delete"), role: .destructive) {
                    Task { await perform(action) }
                }
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: { action in
            confirmationMessage(for: action)
        }
        .alert(
            String(localized: "Household Recovery"),
            isPresented: Binding(get: { completionMessage != nil }, set: { if !$0 { completionMessage = nil } })
        ) {
            Button(String(localized: "OK")) {}
        } message: {
            Text(completionMessage ?? "")
        }
        .alert(
            String(localized: "Couldn’t complete recovery"),
            isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
        ) {
            Button(String(localized: "OK")) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var list: some View {
        List {
            Section {
                Label {
                    Text("Choose the exact iCloud household to restore. MealPlan never guesses between old, shared, or similarly named households here.")
                } icon: {
                    Image(systemName: "person.2.badge.gearshape")
                }
            } footer: {
                Text("Restoring downloads and checks the selected household before this device changes. A timestamped MealPlan backup is retained locally first; your iCloud household is not deleted or overwritten.")
            }

            if let progress, isWorking {
                Section {
                    LabeledContent(String(localized: "Recovery"), value: progressText(progress))
                    ProgressView()
                }
            }

            Section {
                if households.isEmpty {
                    ContentUnavailableView(
                        String(localized: "No recoverable iCloud households"),
                        systemImage: "icloud.slash",
                        description: Text("Check that you are signed in to iCloud, then refresh."))
                } else {
                    ForEach(households) { household in
                        Button {
                            pendingAction = .restore(household)
                        } label: {
                            householdRow(household, action: String(localized: "Reset & Restore"))
                        }
                        .disabled(isWorking)
                        .buttonStyle(.plain)
                    }
                }
            } header: {
                Text("Restore Household from iCloud")
            } footer: {
                Text("Private zones and already accepted shared zones are listed separately when they are distinct. The selected zone, UUID, and share are re-adopted exactly as shown.")
            }

            if !recentlyDeleted.isEmpty {
                Section {
                    ForEach(recentlyDeleted) { household in
                        VStack(alignment: .leading, spacing: 10) {
                            Button {
                                pendingAction = .restore(household)
                            } label: {
                                householdRow(household, action: String(localized: "Reset & Restore"))
                            }
                            .disabled(isWorking)
                            .buttonStyle(.plain)

                            if let retentionUntil = household.retentionUntil {
                                if household.isPurgeEligible {
                                    Button(role: .destructive) {
                                        pendingAction = .purge(household)
                                    } label: {
                                        Label(String(localized: "Permanently Delete"), systemImage: "trash")
                                    }
                                    .disabled(isWorking)
                                } else {
                                    Label {
                                        Text("Available for permanent deletion after \(retentionUntil, format: .dateTime.day().month().year()).")
                                    } icon: {
                                        Image(systemName: "clock")
                                    }
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Recently Deleted")
                } footer: {
                    Text("These owner households still live in their original iCloud zones for 30 days. Restoring preserves their record UUIDs and, where iCloud still permits it, their share participants.")
                }
            }

            if !safetyBackups.isEmpty {
                Section {
                    ForEach(safetyBackups) { backup in
                        Button {
                            pendingAction = .restoreSafetyBackup(backup)
                        } label: {
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: "externaldrive.badge.checkmark")
                                    .font(.title3)
                                    .foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(backup.backup.household.name).font(.headline)
                                    Text(BackupSummary.sentence(for: backup.backup.contents))
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                    Text(backup.backup.exportedAt, format: .dateTime.day().month().year().hour().minute())
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 8)
                                Text("Restore")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(Color.accentColor)
                            }
                            .contentShape(Rectangle())
                        }
                        .disabled(isWorking)
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("Local Safety Backups")
                } footer: {
                    Text("These checkpoints use the ordinary MealPlan backup format and keep the matching local iCloud locator in a private sidecar. They remain available if an interrupted restore needs recovery while iCloud is offline.")
                }
            }

            if let current = appState.currentHousehold,
               HouseholdCloudSharingService.isOwner(shareIdentifier: current.cloudKitShareIdentifier) ?? true {
                Section {
                    Button(role: .destructive) {
                        let locator = HouseholdShareLocator.decode(current.cloudKitShareIdentifier) ?? .solo(householdID: current.uuid)
                        pendingAction = .moveToRecentlyDeleted(.init(
                            householdID: current.uuid,
                            name: current.name,
                            locator: locator,
                            source: .privateZone,
                            role: .owner,
                            dishCount: current.dishes?.count ?? 0,
                            entryCount: current.entries?.count ?? 0,
                            memberCount: current.members?.filter(\.isActive).count ?? 0,
                            entryStart: current.entries?.map(\.date).min(),
                            entryEnd: current.entries?.map(\.date).max(),
                            dateCreated: current.dateCreated,
                            lastModifiedAt: current.modifiedAt,
                            isShared: locator.shareRecordName != nil,
                            isActiveOnThisDevice: true,
                            deletedAt: nil,
                            retentionUntil: nil
                        ))
                    } label: {
                        Label(String(localized: "Move Current Household to Recently Deleted"), systemImage: "trash.slash")
                    }
                    .disabled(isWorking)
                } header: {
                    Text("Owner controls")
                } footer: {
                    Text("This only resets this device after iCloud has recorded a recovery entry. The original zone and its shared household stay intact for 30 days. Participants leaving a shared household can never delete the owner’s data.")
                }
            }

            Section {
                NavigationLink {
                    DataTransferView()
                } label: {
                    Label(String(localized: "Export Backup"), systemImage: "square.and.arrow.up")
                }
            } footer: {
                Text("Create a portable MealPlan backup yourself before a recovery, or keep one somewhere outside this device. Recovery also creates its own local safety checkpoint automatically.")
            }

            Section {
                Button {
                    Task { await refresh() }
                } label: {
                    Label(String(localized: "Refresh iCloud Households"), systemImage: "arrow.clockwise")
                }
                .disabled(isWorking)

                Button {
                    showsDiagnostics.toggle()
                } label: {
                    Label(String(localized: "Recovery Diagnostics"), systemImage: "stethoscope")
                }
            } footer: {
                Text("Diagnostics contain identifiers, database scope, zone and share references only—never recipe, ingredient, address, or member-name content.")
            }

            if showsDiagnostics {
                Section(String(localized: "Diagnostics")) {
                    LabeledContent(String(localized: "iCloud environment"), value: BuildEnvironment.cloudKit.localizedName)
                    ForEach(households + recentlyDeleted) { household in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(household.householdID.uuidString)
                                .font(.caption.monospaced())
                            Text(household.diagnostics)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .refreshable { await refresh() }
    }

    private func householdRow(_ household: HouseholdRecoveryCandidate, action: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: household.source == .recentlyDeleted ? "trash.circle" : household.isShared ? "person.2.circle" : "house.circle")
                .font(.title3)
                .foregroundStyle(household.source == .recentlyDeleted ? .orange : Color.accentColor)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(household.name).font(.headline)
                    if household.isActiveOnThisDevice {
                        Text("This device")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                }
                Text(summary(for: household))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(detail(for: household))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(action)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.accentColor)
        }
        .contentShape(Rectangle())
    }

    private func summary(for household: HouseholdRecoveryCandidate) -> String {
        "\(household.dishCount) dishes · \(household.entryCount) planned meals · \(household.memberCount) members"
    }

    private func detail(for household: HouseholdRecoveryCandidate) -> String {
        var parts = [household.isShared ? String(localized: "Shared") : String(localized: "Private")]
        parts.append(roleText(household.role))
        parts.append(String(localized: "Created \(household.dateCreated, format: .dateTime.day().month().year())"))
        parts.append(String(localized: "Updated \(household.lastModifiedAt, format: .dateTime.day().month().year())"))
        if let first = household.entryStart, let last = household.entryEnd {
            parts.append(String(localized: "Plan \(first, format: .dateTime.day().month().year())–\(last, format: .dateTime.day().month().year())"))
        }
        return parts.joined(separator: " · ")
    }

    private func roleText(_ role: HouseholdRecoveryRole) -> String {
        switch role {
        case .owner: String(localized: "Owner")
        case .editor: String(localized: "Can edit")
        case .viewer: String(localized: "View only")
        }
    }

    private func confirmationMessage(for action: RecoveryAction) -> Text {
        switch action {
        case .restore(let household):
            Text("Target: \(household.name), \(household.dishCount) dishes, \(household.entryCount) planned meals. Only the data on this device will be replaced. MealPlan downloads and validates that exact iCloud zone first, writes a timestamped safety backup, then restarts sync only after a successful replacement. Your iCloud household is not deleted.")
        case .restoreSafetyBackup(let backup):
            Text("Target: \(backup.backup.household.name), written \(backup.backup.exportedAt, format: .dateTime.day().month().year().hour().minute()). Only the data on this device will be replaced. MealPlan first writes another safety checkpoint, then restores this ordinary MealPlan backup and its original local iCloud locator.")
        case .moveToRecentlyDeleted(let household):
            Text("Target: \(household.name). MealPlan first saves a timestamped local backup and records the exact iCloud zone in your private recovery index. This device will start with a new empty household. The original household, its UUID, and its iCloud share stay recoverable for 30 days.")
        case .purge(let household):
            Text("Target: \(household.name). This is irreversible: the original iCloud household zone and its recovery entry will be permanently deleted. Shared participants will lose access. This action is available only after the 30-day recovery period.")
        }
    }

    private func progressText(_ progress: HouseholdCloudDownloadProgress) -> String {
        switch progress {
        case .lookingForHousehold: String(localized: "Looking for household")
        case .connecting: String(localized: "Connecting to iCloud")
        case .downloading(let count): String(localized: "Downloaded \(count) records")
        case .importing(let completed, let total): String(localized: "Checking \(completed) of \(total) records")
        }
    }

    private func refresh() async {
        guard !isWorking else { return }
        isLoading = true
        defer { isLoading = false }
        // A checkpoint must remain recoverable while offline, precisely when
        // the iCloud list cannot be refreshed.
        safetyBackups = HouseholdRecoveryService.safetyBackups()
        do {
            let activeID = appState.currentHousehold?.uuid
            let remote = try await HouseholdCloudBootstrapService.recoverableHouseholds(activeHouseholdID: activeID)
            let deleted = try await HouseholdRecoveryIndex.recentlyDeletedHouseholds()
            let deletedZones = Set(deleted.map { "\($0.locator.ownerName)|\($0.locator.zoneName)" })
            households = remote.filter { !deletedZones.contains("\($0.locator.ownerName)|\($0.locator.zoneName)") }
            recentlyDeleted = deleted
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func perform(_ action: RecoveryAction) async {
        pendingAction = nil
        isWorking = true
        progress = .connecting
        defer {
            isWorking = false
            progress = nil
        }
        do {
            switch action {
            case .restore(let household):
                let result = try await HouseholdRecoveryService.restore(
                    household,
                    appState: appState,
                    context: context,
                    progress: { progress = $0 }
                )
                completionMessage = result.didRestartSync
                    ? "Restored \(household.name) on this device. Your pre-recovery backup is saved as \(result.safetyBackupURL.lastPathComponent)."
                    : "Restored \(household.name) on this device. Your pre-recovery backup is saved as \(result.safetyBackupURL.lastPathComponent). iCloud sync will retry when available."
            case .restoreSafetyBackup(let backup):
                let result = try await HouseholdRecoveryService.restoreSafetyBackup(
                    backup,
                    appState: appState,
                    context: context
                )
                completionMessage = result.didRestartSync
                    ? "Restored the local safety backup for \(backup.backup.household.name). A new checkpoint is saved as \(result.safetyBackupURL.lastPathComponent)."
                    : "Restored the local safety backup for \(backup.backup.household.name). iCloud sync will retry when available."
            case .moveToRecentlyDeleted(let household):
                guard let current = appState.currentHousehold else {
                    throw HouseholdRecoveryError.invalidSelection
                }
                let result = try await HouseholdRecoveryService.moveToRecentlyDeleted(
                    household: current,
                    appState: appState,
                    context: context
                )
                completionMessage = "Moved \(household.name) to Recently Deleted. It can be restored for 30 days; the local safety backup is \(result.safetyBackupURL.lastPathComponent)."
            case .purge(let household):
                try await HouseholdRecoveryIndex.purge(household)
                completionMessage = "Permanently deleted \(household.name) from iCloud."
            }
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

#Preview {
    NavigationStack { HouseholdRecoveryView() }
        .environment(AppState.preview)
        .modelContainer(PreviewData.container)
}
