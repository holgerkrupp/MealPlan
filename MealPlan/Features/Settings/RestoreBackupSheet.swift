import SwiftUI
import SwiftData

struct RestorableBackup: Identifiable {
    let id = UUID()
    let backup: MealPlanBackup
}

/// Shows what a backup holds, then replaces the store with it.
///
/// Restoring is the one genuinely destructive thing MealPlan does, so the file
/// is read and summarised *before* anything is touched — the family that is
/// about to be overwritten, the counts that will replace the current ones, and
/// which build the file came from.
@MainActor
struct RestoreBackupSheet: View {
    let backup: RestorableBackup

    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var isRestoring = false
    @State private var confirming = false
    @State private var errorMessage: String?

    private var contents: MealPlanBackup.Contents { backup.backup.contents }

    private var sourceCloudEnvironment: CloudKitEnvironment? {
        guard let raw = backup.backup.origin?.cloudEnvironment,
              let environment = CloudKitEnvironment(rawValue: raw),
              environment != .unknown else { return nil }
        return environment
    }

    private var isCrossEnvironmentRestore: Bool {
        guard let sourceCloudEnvironment,
              BuildEnvironment.cloudKit != .unknown else { return false }
        return sourceCloudEnvironment != BuildEnvironment.cloudKit
    }

    var body: some View {
        NavigationStack {
            Group {
                if isRestoring {
                    ProgressView(String(localized: "Restoring…"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    details
                }
            }
            .navigationTitle(String(localized: "Restore backup"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel")) { dismiss() }
                        .disabled(isRestoring)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Restore")) { confirming = true }
                        .disabled(isRestoring)
                }
            }
            .confirmationDialog(
                String(localized: "Replace everything on this device?"),
                isPresented: $confirming,
                titleVisibility: .visible
            ) {
                Button(String(localized: "Replace everything"), role: .destructive) {
                    Task { await restore() }
                }
                Button(String(localized: "Cancel"), role: .cancel) {}
            } message: {
                Text(replaceWarning)
            }
            .alert(
                String(localized: "Couldn’t restore that backup"),
                isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
            ) {
                Button(String(localized: "OK"), role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 500)
        #else
        .presentationDetents([.medium, .large])
        #endif
    }

    // MARK: - Details

    private var details: some View {
        List {
            Section {
                LabeledContent(String(localized: "Household"), value: backup.backup.household.name)
                LabeledContent(String(localized: "Sync mode"), value: backupSyncMode)
                LabeledContent(String(localized: "Written")) {
                    Text(backup.backup.exportedAt, format: .dateTime.day().month().year().hour().minute())
                }
                if let origin = backup.backup.origin {
                    if let environment = origin.cloudEnvironment {
                        LabeledContent(String(localized: "From build"), value: environment)
                    }
                    if let version = origin.appVersion {
                        LabeledContent(
                            String(localized: "App version"),
                            value: origin.build.map { "\(version) (\($0))" } ?? version
                        )
                    }
                }
                if contents.households > 1 {
                    LabeledContent(
                        String(localized: "Households in file"),
                        value: String(contents.households)
                    )
                }
                if isCrossEnvironmentRestore {
                    Label {
                        Text(crossEnvironmentNotice)
                    } icon: {
                        Image(systemName: "arrow.triangle.2.circlepath.icloud")
                            .foregroundStyle(.orange)
                    }
                    .font(.footnote)
                }
            } header: {
                Text("This file")
            }

            Section(String(localized: "It contains")) {
                LabeledContent(String(localized: "Dishes"), value: "\(contents.dishes)")
                LabeledContent(String(localized: "Planned meals"), value: "\(contents.plannedMeals)")
                LabeledContent(String(localized: "Cooked meals"), value: "\(contents.cookedMeals)")
                LabeledContent(String(localized: "Routines"), value: "\(contents.routines)")
                LabeledContent(String(localized: "Shopping list"), value: "\(contents.shoppingItems)")
                LabeledContent(String(localized: "Week templates"), value: "\(contents.weekTemplates)")
                LabeledContent(
                    String(localized: "Photos"),
                    value: backup.backup.includesPhotos
                        ? "\(contents.photos)"
                        : String(localized: "Not included")
                )
            }

            Section(String(localized: "Current device")) {
                LabeledContent(
                    String(localized: "Household"),
                    value: appState.currentHousehold?.name ?? String(localized: "None")
                )
                LabeledContent(String(localized: "Sync mode"), value: currentSyncMode)
                LabeledContent(String(localized: "Dishes"), value: "\(count(Dish.self))")
                LabeledContent(String(localized: "Planned meals"), value: "\(count(MealPlanEntry.self))")
                LabeledContent(String(localized: "Cooked meals"), value: "\(count(CookedLog.self))")
            }

            Section {
                Label {
                    Text(replaceWarning)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                .font(.footnote)
            }
        }
    }

    private var replaceWarning: String {
        if isCrossEnvironmentRestore,
           let sourceCloudEnvironment {
            return "This backup came from the " + sourceCloudEnvironment.localizedName + " iCloud environment, while this build uses " + BuildEnvironment.cloudKit.localizedName + ". Everything now on this device is deleted first, and the restore creates a new household here so stale records from the other environment are not reused. This can’t be undone."
        }
        return String(localized: "Everything now on this device is deleted first. The restored household is then used for this build’s iCloud environment. This can’t be undone.")
    }

    private var crossEnvironmentNotice: String {
        guard let sourceCloudEnvironment else { return "" }
        return "Different iCloud environment: " + sourceCloudEnvironment.localizedName + " → " + BuildEnvironment.cloudKit.localizedName + ". A new household identity will be created here."
    }

    private var backupSyncMode: String {
        guard let environment = backup.backup.origin?.cloudEnvironment,
              !environment.isEmpty,
              environment != CloudKitEnvironment.unknown.rawValue else {
            return String(localized: "Backup file")
        }
        return "iCloud · CKSyncEngine (" + environment + ")"
    }

    private var currentSyncMode: String {
        "iCloud · CKSyncEngine (" + BuildEnvironment.cloudKit.localizedName + ")"
    }

    private func count<T: PersistentModel>(_ type: T.Type) -> Int {
        (try? context.fetchCount(FetchDescriptor<T>())) ?? 0
    }

    // MARK: - Work

    private func restore() async {
        isRestoring = true
        // The restore itself has to run on the main actor — it is thousands of
        // `ModelContext` operations — so give SwiftUI one turn to put the
        // progress view on screen before the main thread stops answering.
        try? await Task.sleep(for: .milliseconds(50))
        do {
            // Do not let the save observer turn the replacement into a stream
            // of deletes and re-uploads against the old household while the
            // store is being rewritten.
            let oldLocators = (try? context.fetch(FetchDescriptor<Household>()))?
                .compactMap { HouseholdShareLocator.decode($0.cloudKitShareIdentifier) } ?? []
            await HouseholdRecordSyncService.shared.stop()
            for locator in oldLocators {
                HouseholdRecordSyncService.shared.discardState(for: locator)
            }

            try MealPlanBackupRestore.replaceEverything(
                with: backup.backup,
                context: context,
                householdUUID: isCrossEnvironmentRestore ? UUID() : nil
            )
            // `currentHousehold` pointed at one of the deleted objects, and the
            // restored plan needs its routines scheduled forward again.
            appState.bootstrap(context: context)
            if let household = appState.currentHousehold {
                // The restored backup intentionally has no share locator. The
                // next round creates a clean solo zone for its household UUID.
                try? await HouseholdCloudSharingService.synchronize(household, context: context)
            }
            // The dinner reminder was scheduled against meals that no longer
            // exist.
            MealNotificationScheduler.shared.settingsChanged(context: context)
            SharedStore.reloadWidgets()
            appState.importNotice = String(
                localized: "Restored \(contents.dishes) dishes and \(contents.plannedMeals) planned meals."
            )
            dismiss()
        } catch {
            isRestoring = false
            errorMessage = error.localizedDescription
        }
    }
}

#Preview {
    RestoreBackupSheet(
        backup: RestorableBackup(
            backup: (try? MealPlanBackup.make(from: PreviewData.container.mainContext))
                ?? MealPlanBackup(household: .init(
                    uuid: UUID(),
                    name: "Family",
                    unitSystemRaw: UnitSystem.metric.rawValue,
                    roundsDisplayedAmounts: true,
                    calendarStyleRaw: CalendarStyle.week.rawValue,
                    localeIdentifier: Locale.current.identifier,
                    dateCreated: .now
                ))
        )
    )
    .environment(AppState.preview)
    .modelContainer(PreviewData.container)
}
