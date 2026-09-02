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
    }

    // MARK: - Details

    private var details: some View {
        List {
            Section {
                LabeledContent(String(localized: "Family"), value: backup.backup.household.name)
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
        if SharedStore.isMirroringToCloudKit {
            String(localized: "Everything now on this device is deleted first, including anything already synced to this iCloud database on your other devices. This can’t be undone.")
        } else {
            String(localized: "Everything now on this device is deleted first. This can’t be undone.")
        }
    }

    // MARK: - Work

    private func restore() async {
        isRestoring = true
        // The restore itself has to run on the main actor — it is thousands of
        // `ModelContext` operations — so give SwiftUI one turn to put the
        // progress view on screen before the main thread stops answering.
        try? await Task.sleep(for: .milliseconds(50))
        do {
            try MealPlanBackupRestore.replaceEverything(with: backup.backup, context: context)
            // `currentHousehold` pointed at one of the deleted objects, and the
            // restored plan needs its routines scheduled forward again.
            appState.bootstrap(context: context)
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
