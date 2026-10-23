import CloudKit
import CollaborationCloudKit
import CollaborationUI
import SwiftData
import SwiftUI
#if os(macOS)
import AppKit
#endif

@MainActor
struct HouseholdSharingView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let household: Household

    @State private var sharing: CloudKitShareLifecycleService?
    @State private var share: CKShare?
    @State private var managedShare: ManagedShareSheet?
    @State private var isLoading = true
    @State private var isPreparingManagement = false
    @State private var errorMessage: String?
    #if os(macOS)
    @State private var macSharingPresenter: NativeMacCloudSharingPresenter?
    #endif

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let sharing {
                    sharingContent(sharing)
                } else {
                    ContentUnavailableView(
                        String(localized: "Sharing unavailable"),
                        systemImage: "icloud.slash",
                        description: Text(errorMessage ?? String(localized: "MealPlan couldn’t prepare household sharing."))
                    )
                    .overlay(alignment: .bottom) {
                        VStack(spacing: 12) {
                            Button(String(localized: "Try Again")) {
                                Task { await loadSharing() }
                            }
                            .buttonStyle(.borderedProminent)

                            ShareLink(item: HouseholdSyncDiagnostics.supportReport()) {
                                Label(String(localized: "Share Diagnostics"), systemImage: "square.and.arrow.up")
                            }
                        }
                        .padding(.bottom, 28)
                    }
                }
            }
            .navigationTitle(String(localized: "Share household"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Done")) { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 420)
        #endif
        .task { await loadSharing() }
        .onChange(of: household.cloudKitShareIdentifier) {
            Task { await refreshShare() }
        }
        .sheet(item: $managedShare) { item in
            #if os(iOS)
            if let sharing {
                NativeCloudSharingController(
                    share: item.share,
                    title: household.name,
                    rootID: household.uuid.uuidString,
                    sharing: sharing,
                    onShareChanged: { Task { await refreshShareAndMembers() } },
                    onStopSharing: { Task { await stopSharingLocally() } },
                    onFailure: { errorMessage = $0.localizedDescription }
                )
                .ignoresSafeArea()
            }
            #else
            EmptyView()
            #endif
        }
    }

    @ViewBuilder
    private func sharingContent(_ sharing: CloudKitShareLifecycleService) -> some View {
        ScrollView {
            VStack(spacing: 22) {
                Image(systemName: "person.2.badge.plus")
                    .font(.system(size: 38, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 82, height: 82)
                    .background(Color.accentColor.opacity(0.12), in: Circle())

                VStack(spacing: 8) {
                    Text(String(localized: "Plan together"))
                        .font(.title2.bold())
                    Text(String(localized: "Invite your family to share dishes, meal plans, and the shopping list."))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if share != nil {
                    manageSharingButton(using: sharing)
                    CloudKitShareLink(
                        rootID: household.uuid.uuidString,
                        title: household.name,
                        container: sharing.cloudKitContainer,
                        sharing: sharing
                    ) {
                        Label(String(localized: "Invite or share again"), systemImage: "person.crop.circle.badge.plus")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                } else {
                    CloudKitShareLink(
                        rootID: household.uuid.uuidString,
                        title: household.name,
                        container: sharing.cloudKitContainer,
                        sharing: sharing
                    ) {
                        Label(String(localized: "Share household"), systemImage: "person.crop.circle.badge.plus")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text(String(localized: "People in this household"))
                        .font(.headline)
                    let people = (household.members ?? []).filter(\.isActive).sorted { $0.dateAdded < $1.dateAdded }
                    if people.isEmpty {
                        Text(String(localized: "Your household is ready for invitations."))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(people) { member in
                            HStack(spacing: 12) {
                                Image(systemName: member.isCurrentUser ? "person.crop.circle.fill" : "person.crop.circle")
                                    .foregroundStyle(member.isCurrentUser ? Color.accentColor : .secondary)
                                Text(member.isCurrentUser ? String(localized: "You · \(member.name)") : member.name)
                                Spacer()
                                Text(member.role.localizedName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 5)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
            }
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
            .padding(24)
        }
    }

    private func manageSharingButton(using sharing: CloudKitShareLifecycleService) -> some View {
        Button {
            Task { await presentManagement(using: sharing) }
        } label: {
            if isPreparingManagement {
                ProgressView()
                    .frame(maxWidth: .infinity)
            } else {
                Label(String(localized: "Manage access"), systemImage: "person.2")
                    .frame(maxWidth: .infinity)
            }
        }
        .disabled(isPreparingManagement)
        .buttonStyle(.borderedProminent)
    }

    private func presentManagement(using sharing: CloudKitShareLifecycleService) async {
        guard !isPreparingManagement else { return }
        isPreparingManagement = true
        defer { isPreparingManagement = false }
        do {
            // Revalidate the authoritative share only when the owner asks to
            // manage it. This also migrates legacy public-link shares before
            // Apple's participant manager opens.
            let prepared = try await sharing.prepareShare(
                rootID: household.uuid.uuidString,
                waitTimeout: .seconds(45)
            )
            share = prepared
            errorMessage = nil
            #if os(iOS)
            managedShare = ManagedShareSheet(share: prepared)
            #else
            let presenter = NativeMacCloudSharingPresenter()
            presenter.onShareSaved = { _ in Task { await refreshShareAndMembers() } }
            presenter.onSharingStopped = { _ in Task { await stopSharingLocally() } }
            presenter.onCompleted = { errorMessage = $0?.localizedDescription }
            presenter.present(share: prepared, rootID: household.uuid.uuidString, sharing: sharing)
            macSharingPresenter = presenter
            #endif
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadSharing() async {
        isLoading = true
        sharing = nil
        share = nil
        errorMessage = nil
        do {
            let service = try await MealPlanCloudSharing.service(for: household, context: modelContext)
            sharing = service
            share = try await service.existingShare(rootID: household.uuid.uuidString)
            errorMessage = nil
        } catch {
            if let localized = error as? LocalizedError,
               let suggestion = localized.recoverySuggestion {
                errorMessage = "\(error.localizedDescription)\n\n\(suggestion)"
            } else {
                errorMessage = error.localizedDescription
            }
        }
        isLoading = false
    }

    private func refreshShare() async {
        guard let sharing else { return }
        do {
            share = try await sharing.existingShare(rootID: household.uuid.uuidString)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func refreshShareAndMembers() async {
        await refreshShare()
        do {
            try await HouseholdCloudSharingService.synchronize(household, context: modelContext)
            try modelContext.save()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func stopSharingLocally() async {
        var locator = HouseholdShareLocator.decode(household.cloudKitShareIdentifier)
            ?? .solo(householdID: household.uuid)
        locator.shareRecordName = nil
        household.cloudKitShareIdentifier = try? HouseholdShareLocator.encode(locator)
        try? modelContext.save()
        share = nil
    }
}

private struct ManagedShareSheet: Identifiable {
    let share: CKShare
    var id: String { share.recordID.recordName }
}
