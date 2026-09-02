import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftData
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Presents a one-time iCloud invitation link for the current household,
/// with a QR code as a nearby-device fallback — the same shape as Family
/// Budget's sharing sheet. See `HouseholdCloudSharingService` for why this
/// isn't the system `UICloudSharingController`: the share this app can
/// actually keep in sync carries a `MealPlanBackup` payload, not a live
/// SwiftData record graph, so there is no CloudKit-native participant roster
/// to hand that controller.
struct HouseholdSharingView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    let household: Household

    @State private var canEdit = true
    @State private var invitation: HouseholdShareInvitation?
    @State private var errorMessage: String?
    @State private var isPreparing = true
    @State private var didCopyLink = false

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
                } else if let invitation {
                    invitationContent(invitation)
                } else {
                    ContentUnavailableView(
                        String(localized: "Sharing unavailable"),
                        systemImage: "icloud.slash",
                        description: Text(errorMessage ?? String(localized: "The invitation could not be prepared."))
                    )
                }
            }
            .padding(24)
            .navigationTitle(String(localized: "Share \(household.name)"))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Done")) { dismiss() }
                }
            }
        }
        .frame(minWidth: 440, minHeight: 620)
        .task { await prepareInvitation() }
    }

    @ViewBuilder
    private func invitationContent(_ invitation: HouseholdShareInvitation) -> some View {
        ScrollView {
            VStack(spacing: 22) {
                Image(systemName: "person.2.badge.plus")
                    .font(.system(size: 38, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 82, height: 82)
                    .background(Color.accentColor.opacity(0.12), in: Circle())

                VStack(spacing: 7) {
                    Text(invitation.isOwner ? "Invite someone to plan with you" : "Share the invitation")
                        .font(.title2.bold())
                        .multilineTextAlignment(.center)
                    Text("Everyone who accepts sees the same dishes and plan.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                if invitation.isOwner {
                    Picker(String(localized: "Access"), selection: $canEdit) {
                        Text("Can edit").tag(true)
                        Text("View only").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: canEdit) { _, _ in Task { await prepareInvitation() } }
                }

                VStack(spacing: 12) {
                    ShareLink(
                        item: invitation.url,
                        subject: Text("Join \(household.name) in MealPlan"),
                        message: Text("Open this invitation to plan meals together in MealPlan.")
                    ) {
                        Label("Send Invitation", systemImage: "message.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    Button {
                        copy(invitation.url)
                    } label: {
                        Label(didCopyLink ? "Invitation Copied" : "Copy Invitation Link", systemImage: didCopyLink ? "checkmark" : "link")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }

                VStack(spacing: 12) {
                    Text("Or scan nearby")
                        .font(.headline)
                    if let qrCode = qrCode(for: invitation.url) {
                        qrCode
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 220, height: 220)
                            .padding(14)
                            .background(.white, in: RoundedRectangle(cornerRadius: 14))
                            .accessibilityLabel("QR code for the household invitation")
                    }
                    Text("Open the Camera app on the other phone and point it at this code.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "lock.icloud")
                        .foregroundStyle(Color.accentColor)
                    Text(invitation.isOwner
                        ? (canEdit
                            ? "This one-time invitation grants edit access, so only send it to someone you trust."
                            : "This one-time invitation grants view-only access.")
                        : "The household stays in iCloud.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .padding(14)
                .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))

                Text(accessSummary(for: invitation.participantCount))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 480)
            .frame(maxWidth: .infinity)
        }
    }

    private func prepareInvitation() async {
        isPreparing = true
        do {
            invitation = try await HouseholdCloudSharingService.prepareInvitation(for: household, canEdit: canEdit, context: modelContext)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        isPreparing = false
    }

    private func qrCode(for url: URL) -> Image? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.absoluteString.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let image = CIContext(options: [.useSoftwareRenderer: false]).createCGImage(output, from: output.extent) else {
            return nil
        }
        return Image(decorative: image, scale: 1)
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

    private func accessSummary(for participantCount: Int) -> String {
        participantCount == 1
            ? String(localized: "1 person currently has access.")
            : String(localized: "\(participantCount) people currently have access.")
    }
}
