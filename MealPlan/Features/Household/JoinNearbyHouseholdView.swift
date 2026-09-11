import SwiftUI

/// The invitee's side of adding someone nearby (see `NearbyInvite`): makes
/// this device visible to the owner's "Share with family" sheet, hands over
/// this Apple Account's iCloud identity when the owner adds it, and joins with
/// the link that comes back. Opened from Household settings, or by scanning
/// the owner's single-use code, which supplies `code`.
struct JoinNearbyHouseholdView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("nearbyJoinName") private var name: String = DeviceOwner.name
    @State private var guest: NearbyInviteGuest
    @State private var isJoining = false
    @State private var joinError: String?

    init(code: String?) {
        _guest = State(initialValue: NearbyInviteGuest(code: code))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .font(.system(size: 36, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 82, height: 82)
                        .background(Color.accentColor.opacity(0.12), in: Circle())

                    VStack(spacing: 8) {
                        Text("Join a Household Nearby")
                            .font(.title2.bold())
                            .multilineTextAlignment(.center)
                        Text(guest.code == nil
                            ? "On the owner’s device, open Share with family. Your name appears under Add Someone Nearby, and they add you with one tap."
                            : "Keep this screen open near the device showing the code. You’re added as soon as it finds you.")
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }

                    if guest.code == nil {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Your name")
                                .font(.headline)
                            TextField(String(localized: "Your name"), text: $name)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit { Task { await guest.start(name: name) } }
                            Text("Shown on the owner’s device so they know it’s you.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                    }

                    status
                }
                .frame(maxWidth: 480)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
            }
            .navigationTitle(String(localized: "Join Nearby"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel")) { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 480)
        #endif
        .task { await guest.start(name: name) }
        .onDisappear { guest.stop() }
        .onChange(of: guest.state) { _, state in
            if case .received(let url) = state {
                Task { await join(url) }
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        if let joinError {
            failure(joinError)
        } else if isJoining {
            progress(String(localized: "Joining the household…"))
        } else {
            switch guest.state {
            case .preparing:
                progress(String(localized: "Getting ready…"))
            case .waiting:
                progress(guest.code == nil
                    ? String(localized: "Waiting for the owner to add you…")
                    : String(localized: "Looking for the owner’s device…"))
            case .connected:
                progress(String(localized: "Connected. Adding you to the household…"))
            case .received:
                progress(String(localized: "Joining the household…"))
            case .failed(let message):
                failure(message)
            }
        }
    }

    private func progress(_ text: String) -> some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
            Text(text)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 8)
    }

    private func failure(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(String(localized: "Try Again")) {
                joinError = nil
                Task { await guest.start(name: name) }
            }
            .buttonStyle(.borderedProminent)
        }
    }

    /// Hands the link to the same acceptance path a tapped iCloud link takes,
    /// including RootView's "replace your household?" question. The owner's
    /// share save can take a moment to reach iCloud, so a lookup that says
    /// this account isn't invited yet is retried briefly.
    private func join(_ url: URL) async {
        isJoining = true
        var lastError: Error?
        for attempt in 0..<5 {
            do {
                let metadata = try await HouseholdCloudSharingService.fetchMetadata(for: url)
                // Out of the way first: RootView's own confirmation and
                // progress take over from here.
                dismiss()
                try? await Task.sleep(for: .milliseconds(500))
                HouseholdShareInvitationInbox.shared.enqueue(metadata)
                return
            } catch {
                lastError = error
                if attempt < 4 { try? await Task.sleep(for: .seconds(1.5)) }
            }
        }
        isJoining = false
        joinError = lastError?.localizedDescription ?? String(localized: "The invitation could not be opened.")
    }
}
