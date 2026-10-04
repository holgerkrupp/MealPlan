import SwiftUI
import SwiftData

/// Development-only evidence for the migration safety patch. It intentionally
/// exposes only IDs/counts/error codes, never a household's recipe/member data.
#if DEBUG
@MainActor
struct LegacyHouseholdDiagnosticsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var context
    @State private var records: [LegacyHouseholdDiagnostic] = LegacyHouseholdDiagnostics.recent()
    @State private var isRefreshing = false

    var body: some View {
        List {
            Section("Current legacy state") {
                LabeledContent("Environment", value: BuildEnvironment.cloudKit.localizedName)
                if let household = appState.currentHousehold {
                    LabeledContent("Household UUID", value: household.uuid.uuidString)
                    let locator = HouseholdShareLocator.decode(household.cloudKitShareIdentifier)
                    LabeledContent("Zone", value: locator?.zoneName ?? HouseholdShareLocator.solo(householdID: household.uuid).zoneName)
                    LabeledContent("Scope", value: locator?.isOwner == false ? "Shared" : "Private")
                    LabeledContent("Share record", value: locator?.shareRecordName ?? "None")
                }
                if let lastSync = HouseholdSyncDiagnostics.recent().last {
                    LabeledContent("Pending records", value: "\(lastSync.pendingCount)")
                }
                LabeledContent(
                    "Last sync error",
                    value: HouseholdRecordSyncService.shared.lastError.map { "\(($0 as NSError).domain):\(($0 as NSError).code)" } ?? "None"
                )
                LabeledContent("Recovery", value: recoveryDescription)
                Button("Recheck owned household zones") { Task { await refresh() } }
                    .disabled(isRefreshing)
            }

            Section("Recent events") {
                if records.isEmpty {
                    Text("No legacy collaboration events yet.")
                        .foregroundStyle(.secondary)
                }
                ForEach(records.reversed()) { entry in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.event)
                        Text(entry.at.formatted())
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        if let code = entry.errorCode {
                            Text(code)
                                .font(.footnote.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Collaboration Diagnostics")
    }

    private var recoveryDescription: String {
        switch appState.legacyHouseholdRecovery {
        case .noAction: "No conflicting owned household"
        case .adoptRemote(let id): "Empty local placeholder can adopt \(id.uuidString)"
        case .reviewRequired(let canonical, let competing):
            "Review required: \(canonical.uuidString), \(competing.count) competing"
        }
    }

    private func refresh() async {
        isRefreshing = true
        await appState.inspectLegacyHouseholds(context: context)
        records = LegacyHouseholdDiagnostics.recent()
        isRefreshing = false
    }
}
#endif
