@preconcurrency import CloudKit
import CollaborationCore
import CollaborationUI
import SwiftUI
#if os(macOS)
import AppKit
#endif

@MainActor
struct ManagedHouseholdSharingView: View {
    @Environment(\.dismiss) private var dismiss
    let household: Household
    let collaboration: MealPlanManagedCollaboration

    @State private var session: ManagedCollaborationSession?
    @State private var share: CKShare?
    @State private var isVerified = false
    @State private var isManagingShare = false
    @State private var isShowingHelp = false
    @State private var errorMessage: String?
    @State private var inviteStatus: String?
    #if os(macOS)
    @State private var macPresenter = NativeMacCloudSharingPresenter()
    #endif

    private var isOwner: Bool { collaboration.effectiveAccess(for: household) == .owner }
    private var wasNoticeDismissed: Bool { collaboration.reinviteNoticeWasDismissed(for: household.uuid) }
    private var previousMembers: [HouseholdMember] {
        (household.members ?? []).filter { !$0.isCurrentUser && $0.isActive }
    }

    var body: some View {
        NavigationStack {
            Group {
                if !isVerified {
                    ContentUnavailableView(
                        String(localized: "Household still preparing"),
                        systemImage: "clock.arrow.circlepath",
                        description: Text("Your saved household data is being checked before sharing can resume.")
                    )
                } else if isOwner {
                    ownerContent
                } else {
                    memberContent
                }
            }
            .navigationTitle(String(localized: "Share \(household.name)"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Done")) {
                        if isOwner && isVerified && !wasNoticeDismissed { dismissNotice() }
                        dismiss()
                    }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 480)
        #endif
        .task { await refresh() }
        .onChange(of: session?.state) { _, state in
            guard state == .shareAvailable else { return }
            Task { await refresh() }
        }
        .alert(
            String(localized: "Couldn’t Update Sharing"),
            isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }),
            presenting: errorMessage
        ) { _ in
            Button(String(localized: "OK")) {}
        } message: { Text($0) }
        .alert(
            String(localized: "Invitation accepted"),
            isPresented: Binding(get: { inviteStatus != nil }, set: { if !$0 { inviteStatus = nil } }),
            presenting: inviteStatus
        ) { _ in
            Button(String(localized: "OK")) {}
        } message: { Text($0) }
        #if os(iOS)
        .sheet(isPresented: $isManagingShare) {
            if let share {
                NativeCloudSharingController(
                    share: share,
                    container: collaboration.cloudKitContainer,
                    title: household.name,
                    onShareChanged: { Task { await refresh() } },
                    onStopSharing: { self.share = nil },
                    onFailure: { errorMessage = $0.localizedDescription }
                )
            }
        }
        #endif
        .confirmationDialog(
            String(localized: "Your household needs a new invitation"),
            isPresented: $isShowingHelp,
            titleVisibility: .visible
        ) {
            Button(String(localized: "Try Again")) { Task { await retryInvitation() } }
            Button(String(localized: "Not Now"), role: .cancel) {}
        } message: {
            Text("Your existing recipes and plans are still saved on this device. Ask the household organizer to send a new invitation, then open it from Messages or Mail.")
        }
    }

    private var ownerContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if !wasNoticeDismissed {
                    VStack(alignment: .leading, spacing: 12) {
                        Label(String(localized: "Sharing has been updated"), systemImage: "person.2.badge.plus")
                            .font(.title2.bold())
                        Text("Your recipes, meal plans and shopping lists are still here. Please invite each household member again. The new way is more reliable, faster and smoother to use. You only need to do this once for each person.")
                            .foregroundStyle(.secondary)
                        inviteAction
                        Button(String(localized: "Later")) {
                            dismissNotice()
                            dismiss()
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(20)
                    .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 18))
                } else {
                    Text(String(localized: "Invite one person for each household member. Choose whether they can edit or only view in Apple’s sharing controls."))
                        .foregroundStyle(.secondary)
                    inviteAction
                    if share != nil {
                        Button(action: showShareManagement) {
                            Label(String(localized: "Manage invited people"), systemImage: "person.2")
                        }
                        .buttonStyle(.bordered)
                    }
                }

                if !previousMembers.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(String(localized: "People from your previous household"))
                            .font(.headline)
                        ForEach(previousMembers) { member in
                            Label(member.name, systemImage: "person")
                                .foregroundStyle(.secondary)
                        }
                        Text(String(localized: "This list is a reminder. It does not mean someone has joined the new share."))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                if let status = preparationStatus {
                    Text(status)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(20)
            .frame(maxWidth: 620, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
    }

    @ViewBuilder
    private var inviteAction: some View {
        if let session {
            CloudKitShareLink(session: session, container: collaboration.cloudKitContainer) {
                Label(String(localized: "Invite Members"), systemImage: "person.crop.circle.badge.plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityHint(String(localized: "Opens Apple’s sharing controls to invite a person to this household."))
        } else {
            ProgressView(String(localized: "Checking your household…"))
        }
    }

    private var memberContent: some View {
        VStack(spacing: 18) {
            Image(systemName: "envelope.badge")
                .font(.system(size: 42))
                .foregroundStyle(.tint)
            Text(String(localized: "Your household needs a new invitation"))
                .font(.title2.bold())
                .multilineTextAlignment(.center)
            Text("The way households are shared has changed. Ask the person who manages your household to send you a new invitation. Your existing information will be kept safe while you reconnect.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(String(localized: "Open Invitations")) { Task { await retryInvitation() } }
                .buttonStyle(.borderedProminent)
            Button(String(localized: "Not Now")) { dismiss() }
                .buttonStyle(.bordered)
            Button(String(localized: "Get Help")) { isShowingHelp = true }
                .buttonStyle(.plain)
        }
        .padding(28)
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var preparationStatus: String? {
        guard let state = session?.state else { return nil }
        switch state {
        case .ready: return nil
        case .preparing: return String(localized: "Preparing the invitation…")
        case .shareAvailable: return String(localized: "Your household share is ready.")
        case .preparationTimedOut: return String(localized: "This is taking longer than expected. You can try again; your household data is unchanged.")
        case .retryableFailure: return String(localized: "Sharing is temporarily unavailable. Try again when you’re online.")
        case .terminalFailure: return String(localized: "The invitation could not be prepared. Your household data is unchanged.")
        case .stopped: return String(localized: "Sharing has stopped.")
        }
    }

    private func refresh() async {
        isVerified = collaboration.isVerifiedManagedHousehold(household.uuid)
        guard isVerified else { return }
        do {
            if session == nil { session = try collaboration.makeVerifiedSession(for: household) }
            try session?.refresh()
            share = try collaboration.existingShare(for: household)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func retryInvitation() async {
        let results = await collaboration.retryPendingInvitations()
        if results.contains(where: { $0.outcome == .accepted }) {
            inviteStatus = String(localized: "The invitation was accepted. Your saved information stays here while the new household finishes preparing.")
        } else if results.contains(where: {
            if case .failed = $0.outcome { return true }
            return false
        }) {
            errorMessage = String(localized: "The invitation could not be opened right now. Check your connection and try again.")
        } else {
            isShowingHelp = true
        }
    }

    private func dismissNotice() {
        do { try collaboration.dismissReinviteNotice(for: household.uuid) }
        catch { errorMessage = error.localizedDescription }
    }

    private func showShareManagement() {
        guard let share else { return }
        #if os(iOS)
        isManagingShare = true
        #elseif os(macOS)
        macPresenter.onShareSaved = { updatedShare in
            Task {
                do { try await collaboration.persistUpdatedShare(updatedShare) }
                catch { errorMessage = error.localizedDescription }
            }
        }
        macPresenter.onSharingStopped = { _ in self.share = nil }
        macPresenter.onCompleted = { error in
            if let error { errorMessage = error.localizedDescription }
            Task { await refresh() }
        }
        macPresenter.present(share: share, container: collaboration.cloudKitContainer)
        #endif
    }
}

@MainActor
struct ManagedHouseholdSharingUnavailableView: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let description: String
    let retry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: "clock.arrow.circlepath")
        } description: {
            Text(description)
        } actions: {
            Button(String(localized: "Check again"), action: retry)
                .buttonStyle(.borderedProminent)
            Button(String(localized: "Done")) { dismiss() }
                .buttonStyle(.bordered)
        }
    }
}

@MainActor
struct HouseholdReinviteWaitingView: View {
    @Environment(\.dismiss) private var dismiss
    let canOpenInvitations: Bool
    let openInvitations: () -> Void
    let getHelp: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                Image(systemName: "envelope.badge")
                    .font(.system(size: 42))
                    .foregroundStyle(.tint)
                Text(String(localized: "Your household needs a new invitation"))
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                Text("The way households are shared has changed. Ask the person who manages your household to send you a new invitation. Your existing information will be kept safe while you reconnect.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                if canOpenInvitations {
                    Button(String(localized: "Open Invitations"), action: openInvitations)
                        .buttonStyle(.borderedProminent)
                }
                Button(String(localized: "Not Now")) {
                    onDismiss()
                    dismiss()
                }
                .buttonStyle(.bordered)
                Button(String(localized: "Get Help"), action: getHelp)
                    .buttonStyle(.plain)
            }
            .padding(28)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Done")) {
                        onDismiss()
                        dismiss()
                    }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 420)
        #endif
    }
}
