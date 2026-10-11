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
    @State private var errorMessage: String?
    @State private var isShowingMigrationSheet = false
    #if os(macOS)
    @State private var macSharingPresenter: NativeMacCloudSharingPresenter?
    #endif

    private var hasExistingHouseholdMember: Bool {
        (household.members ?? []).contains { $0.isActive && !$0.isCurrentUser }
    }

    private var migrationPromptKey: String {
        "MealPlan.packageSharing.reinvitePromptShown.\(household.uuid.uuidString)"
    }

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
                        Button(String(localized: "Try Again")) {
                            Task { await loadSharing() }
                        }
                        .buttonStyle(.borderedProminent)
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
        .sheet(isPresented: $isShowingMigrationSheet, onDismiss: markMigrationPromptShown) {
            migrationSheet
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
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

                if let share {
                    manageSharingButton(share, using: sharing)
                    CloudKitShareLink(
                        share: share,
                        container: sharing.cloudKitContainer,
                        title: household.name
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

    @ViewBuilder
    private func manageSharingButton(_ share: CKShare, using sharing: CloudKitShareLifecycleService) -> some View {
        #if os(iOS)
        Button {
            managedShare = ManagedShareSheet(share: share)
        } label: {
            Label(String(localized: "Manage access"), systemImage: "person.2")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        #else
        Button {
            let presenter = NativeMacCloudSharingPresenter()
            presenter.onShareSaved = { _ in Task { await refreshShareAndMembers() } }
            presenter.onSharingStopped = { _ in Task { await stopSharingLocally() } }
            presenter.onCompleted = { errorMessage = $0?.localizedDescription }
            presenter.present(share: share, rootID: household.uuid.uuidString, sharing: sharing)
            macSharingPresenter = presenter
        } label: {
            Label(String(localized: "Manage access"), systemImage: "person.2")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        #endif
    }

    private var migrationSheet: some View {
        VStack(spacing: 18) {
            Image(systemName: "person.2.crop.square.stack")
                .font(.system(size: 38, weight: .semibold))
                .foregroundStyle(Color.accentColor)
            Text(String(localized: "MealPlan sharing is better"))
                .font(.title2.bold())
                .multilineTextAlignment(.center)
            Text(String(localized: "Your household moved automatically. Sharing is now more reliable, faster, and easier to use. Invite the people who already share this household again so they can continue planning with you."))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            if let sharing {
                if let share {
                    CloudKitShareLink(share: share, container: sharing.cloudKitContainer, title: household.name) {
                        Label(String(localized: "Review household invitations"), systemImage: "person.crop.circle.badge.plus")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    CloudKitShareLink(
                        rootID: household.uuid.uuidString,
                        title: household.name,
                        container: sharing.cloudKitContainer,
                        sharing: sharing
                    ) {
                        Label(String(localized: "Review household invitations"), systemImage: "person.crop.circle.badge.plus")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                Button(String(localized: "Done")) { isShowingMigrationSheet = false }
                    .buttonStyle(.borderedProminent)
            }
            Button(String(localized: "Later")) { isShowingMigrationSheet = false }
                .buttonStyle(.plain)
        }
        .padding(28)
        .frame(maxWidth: 460)
    }

    private func loadSharing() async {
        isLoading = true
        do {
            let service = try await MealPlanCloudSharing.service(for: household, context: modelContext)
            sharing = service
            let existingShare = try await service.existingShare(rootID: household.uuid.uuidString)
            share = existingShare
            if existingShare != nil || hasExistingHouseholdMember {
                do {
                    share = try await service.prepareShare(
                        rootID: household.uuid.uuidString,
                        waitTimeout: .seconds(45)
                    )
                    errorMessage = nil
                } catch {
                    errorMessage = error.localizedDescription
                }
            } else {
                errorMessage = nil
            }
            if hasExistingHouseholdMember,
               UserDefaults(suiteName: SharedStore.appGroupID)?.bool(forKey: migrationPromptKey) != true {
                isShowingMigrationSheet = true
            }
        } catch {
            errorMessage = error.localizedDescription
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

    private func markMigrationPromptShown() {
        UserDefaults(suiteName: SharedStore.appGroupID)?.set(true, forKey: migrationPromptKey)
    }
}

private struct ManagedShareSheet: Identifiable {
    let share: CKShare
    var id: String { share.recordID.recordName }
}
