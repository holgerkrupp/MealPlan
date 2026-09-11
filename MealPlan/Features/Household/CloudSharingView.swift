import SwiftData
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Adds people to the current household and lists who is invited or has
/// joined. Two ways in, both naming exactly one Apple Account, so removing
/// someone is final:
/// - **Nearby** — a single-use QR code, or a tap on a device that has "Join a
///   Household Nearby" open; see `NearbyInvite`.
/// - **By Apple Account** — an email address or phone number, then the share
///   link sent by Messages, Mail, or AirDrop.
///
/// See `HouseholdCloudSharingService` for why this isn't the system
/// `UICloudSharingController`.
struct HouseholdSharingView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    let household: Household

    @State private var address = ""
    @State private var canEdit = true
    @State private var invitation: HouseholdShareInvitation?
    @State private var nearbyHost: NearbyInviteHost?
    @State private var errorMessage: String?
    @State private var actionErrorMessage: String?
    @State private var isPreparing = true
    @State private var isInviting = false
    @State private var busyParticipantID: String?
    @State private var participantPendingRemoval: HouseholdShareParticipant?
    @State private var didCopyLink = false
    @State private var isConfirmingNewInvitation = false

    var body: some View {
        NavigationStack {
            Group {
                if isPreparing {
                    VStack(spacing: 16) {
                        ProgressView()
                            .controlSize(.large)
                        Text("Preparing a secure iCloud invitation…")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(24)
                } else if let invitation {
                    invitationContent(invitation)
                } else {
                    VStack(spacing: 20) {
                        ContentUnavailableView(
                            String(localized: "Sharing unavailable"),
                            systemImage: "icloud.slash",
                            description: Text(errorMessage ?? String(localized: "The invitation could not be prepared."))
                        )

                        if isOwner {
                            Button {
                                isConfirmingNewInvitation = true
                            } label: {
                                Label("Create New Invitation", systemImage: "arrow.clockwise")
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                    .padding(24)
                }
            }
            .navigationTitle(String(localized: "Share \(household.name)"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Done")) { dismiss() }
                }
            }
        }
        // A floor for the Mac's sheet only. On an iPhone this forced the sheet
        // wider than the screen and cut off both edges.
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 640)
        #endif
        .task { await prepareInvitation() }
        .onDisappear { nearbyHost?.stop() }
        .confirmationDialog(
            String(localized: "Create a New Invitation?"),
            isPresented: $isConfirmingNewInvitation,
            titleVisibility: .visible
        ) {
            Button(String(localized: "Create New Invitation"), role: .destructive) {
                Task { await replaceInvitation() }
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text("The current link will stop working and everyone you invited will lose access until you invite them again. Your household, dishes, and meal plan will stay intact.")
        }
        .confirmationDialog(
            removalTitle(for: participantPendingRemoval),
            isPresented: Binding(get: { participantPendingRemoval != nil }, set: { if !$0 { participantPendingRemoval = nil } }),
            titleVisibility: .visible,
            presenting: participantPendingRemoval
        ) { person in
            Button(
                person.status == .joined ? String(localized: "Remove from Household") : String(localized: "Withdraw Invitation"),
                role: .destructive
            ) {
                Task { await remove(person) }
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: { person in
            if person.status == .joined {
                Text("\(person.displayName) will lose access to the shared plan and shopping list right away. They keep a copy of the household’s recipes.")
            } else {
                Text("The link will stop working for \(person.displayName).")
            }
        }
        .alert(
            String(localized: "Couldn’t Update Sharing"),
            isPresented: Binding(get: { actionErrorMessage != nil }, set: { if !$0 { actionErrorMessage = nil } }),
            presenting: actionErrorMessage
        ) { _ in
            Button(String(localized: "OK")) {}
        } message: { message in
            Text(message)
        }
    }

    private var isOwner: Bool {
        HouseholdCloudSharingService.isOwner(shareIdentifier: household.cloudKitShareIdentifier) ?? true
    }

    @ViewBuilder
    private func invitationContent(_ invitation: HouseholdShareInvitation) -> some View {
        ScrollView {
            VStack(spacing: 24) {
                VStack(spacing: 12) {
                    Image(systemName: "person.2.badge.plus")
                        .font(.system(size: 36, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 78, height: 78)
                        .background(Color.accentColor.opacity(0.12), in: Circle())
                    Text("Invite someone to plan with you")
                        .font(.title2.bold())
                        .multilineTextAlignment(.center)
                    Text("Everyone who accepts sees the same dishes and plan.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 8)

                VStack(alignment: .leading, spacing: 10) {
                    Text("Access for people you add")
                        .font(.headline)
                    Picker(String(localized: "Access"), selection: $canEdit) {
                        Text("Can edit").tag(true)
                        Text("View only").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                .sharingCard()

                if let nearbyHost {
                    nearbyCard(nearbyHost)
                }

                inviteCard

                if !invitation.invitees.isEmpty {
                    peopleList(invitation.invitees)
                    linkSection(invitation.url)
                }

                Divider()

                VStack(spacing: 8) {
                    Button(role: .destructive) {
                        isConfirmingNewInvitation = true
                    } label: {
                        Label("Create New Invitation", systemImage: "arrow.clockwise")
                    }

                    Text("Use this if iCloud says the current invitation no longer exists. It creates a different link without deleting your household data.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
        }
        #if os(iOS)
        .scrollDismissesKeyboard(.interactively)
        #endif
    }

    private func nearbyCard(_ host: NearbyInviteHost) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Add Someone Nearby", systemImage: "dot.radiowaves.left.and.right")
                .font(.headline)
            Text("Together in the same room? They scan this code with their camera and are added straight away, no email address needed. Each code works once.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            if let matrix = QRCodeMatrix(string: host.codeURL.absoluteString) {
                QRCodeShape(matrix: matrix)
                    .fill(Color.black)
                    .frame(width: 200, height: 200)
                    .padding(14)
                    .background(.white, in: RoundedRectangle(cornerRadius: 14))
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("Single-use QR code for adding someone nearby")
            }

            if let problem = host.problem {
                Text(problem)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            if !host.guests.isEmpty {
                VStack(spacing: 0) {
                    ForEach(host.guests) { guest in
                        nearbyRow(guest, host: host)
                        if guest.id != host.guests.last?.id {
                            Divider()
                        }
                    }
                }
                .padding(.horizontal, 12)
                .background(.background, in: RoundedRectangle(cornerRadius: 10))
            }

            Text("They can also choose Join a Household Nearby in MealPlan’s Household settings, and show up here.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .sharingCard()
    }

    private func nearbyRow(_ guest: NearbyInviteHost.Guest, host: NearbyInviteHost) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "iphone")
                .foregroundStyle(.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(guest.name)
                if case .failed(let message) = guest.state {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            Spacer(minLength: 8)
            switch guest.state {
            case .nearby:
                Button(String(localized: "Add")) { host.add(guest) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            case .adding:
                ProgressView()
                    .controlSize(.small)
            case .added:
                Label(String(localized: "Added"), systemImage: "checkmark.circle.fill")
                    .font(.subheadline)
                    .foregroundStyle(Color.accentColor)
            case .failed:
                Button(String(localized: "Try Again")) { host.add(guest) }
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 10)
    }

    private var inviteCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Invite by Apple Account", systemImage: "envelope")
                .font(.headline)

            TextField(String(localized: "Email or phone number"), text: $address, prompt: Text(verbatim: "name@example.com"))
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.emailAddress)
                .textContentType(.emailAddress)
                #endif
                .onSubmit { Task { await invite() } }

            Button {
                Task { await invite() }
            } label: {
                Group {
                    if isInviting {
                        ProgressView()
                    } else {
                        Label("Invite", systemImage: "person.badge.plus")
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(HouseholdInviteAddress(address) == nil || isInviting)

            Text("Use the email address or phone number of their Apple Account — with the country code for a phone number. Only the people you invite can open the link.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .sharingCard()
    }

    private func peopleList(_ people: [HouseholdShareParticipant]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("People")
                .font(.headline)
            VStack(spacing: 0) {
                ForEach(people) { person in
                    participantRow(person)
                    if person.id != people.last?.id {
                        Divider()
                    }
                }
            }
            .padding(.horizontal, 16)
            .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private func participantRow(_ person: HouseholdShareParticipant) -> some View {
        HStack(spacing: 12) {
            Image(systemName: person.status == .joined ? "person.crop.circle.badge.checkmark" : "envelope")
                .foregroundStyle(person.status == .joined ? Color.accentColor : .secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(person.displayName)
                Text(statusLine(for: person))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if busyParticipantID == person.id {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button(role: .destructive) {
                    participantPendingRemoval = person
                } label: {
                    Label(
                        person.status == .joined ? String(localized: "Remove") : String(localized: "Withdraw Invitation"),
                        systemImage: "xmark.circle.fill"
                    )
                    .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 12)
    }

    private func linkSection(_ url: URL) -> some View {
        VStack(spacing: 12) {
            VStack(spacing: 4) {
                Text("Send them the link")
                    .font(.headline)
                Text("Share it by Messages, Mail, or AirDrop. It only opens the household for the people listed above.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            ShareLink(
                item: url,
                subject: Text("Join \(household.name) in MealPlan"),
                message: Text("Open this invitation to plan meals together in MealPlan.")
            ) {
                Label("Send Invitation", systemImage: "message.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Button {
                copy(url)
            } label: {
                Label(didCopyLink ? "Invitation Copied" : "Copy Invitation Link", systemImage: didCopyLink ? "checkmark" : "link")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
    }

    private func statusLine(for person: HouseholdShareParticipant) -> String {
        var parts = [
            person.status == .joined ? String(localized: "Joined") : String(localized: "Invited"),
            person.canEdit ? String(localized: "Can edit") : String(localized: "View only"),
        ]
        if let detail = person.detail { parts.insert(detail, at: 0) }
        return parts.joined(separator: " · ")
    }

    private func removalTitle(for person: HouseholdShareParticipant?) -> String {
        guard let person else { return "" }
        return person.status == .joined
            ? String(localized: "Remove \(person.displayName)?")
            : String(localized: "Withdraw the invitation for \(person.displayName)?")
    }

    private func prepareInvitation() async {
        isPreparing = true
        do {
            invitation = try await HouseholdCloudSharingService.prepareInvitation(for: household, context: modelContext)
            errorMessage = nil
            startNearbyIfNeeded()
        } catch {
            errorMessage = error.localizedDescription
        }
        isPreparing = false
    }

    /// Nearby adding needs the share to exist first, so it starts once the
    /// invitation is ready and runs until the sheet closes.
    private func startNearbyIfNeeded() {
        guard nearbyHost == nil else { return }
        let host = NearbyInviteHost(displayName: household.name)
        host.addGuest = { userRecordName in
            let updated = try await HouseholdCloudSharingService.invite(
                userRecordName: userRecordName,
                canEdit: canEdit,
                to: household,
                context: modelContext
            )
            invitation = updated
            return updated.url
        }
        host.start()
        nearbyHost = host
    }

    private func invite() async {
        guard let parsed = HouseholdInviteAddress(address), !isInviting else { return }
        isInviting = true
        defer { isInviting = false }
        do {
            invitation = try await HouseholdCloudSharingService.invite(parsed, canEdit: canEdit, to: household, context: modelContext)
            address = ""
        } catch {
            actionErrorMessage = error.localizedDescription
        }
    }

    private func remove(_ person: HouseholdShareParticipant) async {
        busyParticipantID = person.id
        defer { busyParticipantID = nil }
        do {
            invitation = try await HouseholdCloudSharingService.removeParticipant(withID: person.id, from: household, context: modelContext)
        } catch {
            actionErrorMessage = error.localizedDescription
        }
    }

    private func replaceInvitation() async {
        isPreparing = true
        invitation = nil
        didCopyLink = false
        do {
            invitation = try await HouseholdCloudSharingService.replaceInvitation(for: household, context: modelContext)
            errorMessage = nil
            startNearbyIfNeeded()
        } catch {
            errorMessage = error.localizedDescription
        }
        isPreparing = false
    }

    private func copy(_ url: URL) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        #else
        UIPasteboard.general.url = url
        #endif
        didCopyLink = true
    }
}

private extension View {
    /// One group of controls on the sharing sheet.
    func sharingCard() -> some View {
        padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
    }
}
