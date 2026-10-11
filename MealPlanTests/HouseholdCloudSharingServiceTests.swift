import Testing
import CloudKit
import Foundation
#if canImport(UIKit)
import UIKit
#endif
@testable import MealPlan

/// `isShareURL` decides whether a URL that reached the app through
/// `onOpenURL` (rather than the system's own CloudKit acceptance sheet)
/// should still be treated as a household invitation. See
/// `AppState.handle(openedURL:)`.
@MainActor
struct HouseholdCloudSharingServiceTests {

    @Test func recognizesICloudShareLinks() {
        #expect(HouseholdCloudSharingService.isShareURL(URL(string: "https://www.icloud.com/share/abc123")!))
        #expect(HouseholdCloudSharingService.isShareURL(URL(string: "https://icloud.com/share/abc123")!))
    }

    @Test func ignoresUnrelatedLinks() {
        #expect(!HouseholdCloudSharingService.isShareURL(URL(string: "mealplan://today")!))
        #expect(!HouseholdCloudSharingService.isShareURL(URL(string: "https://www.icloud.com/settings")!))
        #expect(!HouseholdCloudSharingService.isShareURL(URL(string: "https://example.com/share/abc123")!))
    }

    @Test func coalescesDuplicateShareDeliveriesButAllowsRetry() {
        var gate = CloudShareDeliveryGate()

        let firstDelivery = gate.shouldDeliver("container|owner|zone|share")
        let duplicateDelivery = gate.shouldDeliver("container|owner|zone|share")
        #expect(firstDelivery)
        #expect(!duplicateDelivery)

        gate.allowRedelivery("container|owner|zone|share")
        let retryDelivery = gate.shouldDeliver("container|owner|zone|share")
        #expect(retryDelivery)
    }

    @Test func ownerCanRemoveInvitedParticipants() {
        #expect(HouseholdCloudSharingService.canRemove(participant(role: .editor)))
        #expect(HouseholdCloudSharingService.canRemove(participant(role: .guest)))
    }

    @Test func ownerCannotRemoveThemselvesOrStaleRows() {
        #expect(!HouseholdCloudSharingService.canRemove(participant(role: .owner)))

        let currentUser = participant(role: .editor)
        currentUser.isCurrentUser = true
        #expect(!HouseholdCloudSharingService.canRemove(currentUser))

        let alreadyRemoved = participant(role: .editor)
        alreadyRemoved.isActive = false
        #expect(!HouseholdCloudSharingService.canRemove(alreadyRemoved))

        // A member row that never came from a CKShare has nothing to revoke.
        let localOnly = participant(role: .editor)
        localOnly.cloudKitParticipantID = nil
        #expect(!HouseholdCloudSharingService.canRemove(localOnly))
    }

    @Test func parsesAppleAccountEmailAddresses() {
        #expect(HouseholdInviteAddress("  alex@example.com \n") == .email("alex@example.com"))
        #expect(HouseholdInviteAddress("alex@example") == nil)
        #expect(HouseholdInviteAddress("alex@@example.com") == nil)
        #expect(HouseholdInviteAddress("@example.com") == nil)
        #expect(HouseholdInviteAddress("alex smith@example.com") == nil)
    }

    @Test func parsesPhoneNumbersWrittenWithFormatting() {
        #expect(HouseholdInviteAddress("+49 (170) 123-4567") == .phone("+491701234567"))
        #expect(HouseholdInviteAddress("0170 1234567") == .phone("01701234567"))
        #expect(HouseholdInviteAddress("12345") == nil)
        #expect(HouseholdInviteAddress("call me") == nil)
        #expect(HouseholdInviteAddress("") == nil)
    }

    @Test func pendingInviteesAreShownByTheAddressTheyWereInvitedAt() {
        let invited = HouseholdShareParticipant(id: "1", name: nil, emailAddress: "alex@example.com", phoneNumber: nil, isOwner: false, canEdit: true, status: .invited)
        #expect(invited.displayName == "alex@example.com")
        #expect(invited.detail == nil)

        let joined = HouseholdShareParticipant(id: "2", name: "Alex Smith", emailAddress: nil, phoneNumber: "+491701234567", isOwner: false, canEdit: false, status: .joined)
        #expect(joined.displayName == "Alex Smith")
        #expect(joined.detail == "+491701234567")
    }

    /// Losing access turns the household into a new one on that device, so a
    /// passing network or server hiccup must never be read as removal.
    @Test func onlyAMissingShareOrZoneMeansAccessWasLost() {
        #expect(HouseholdCloudSharingService.indicatesLostAccess(CKError(.zoneNotFound)))
        #expect(HouseholdCloudSharingService.indicatesLostAccess(CKError(.unknownItem)))
        #expect(HouseholdCloudSharingService.indicatesLostAccess(CKError(.userDeletedZone)))

        #expect(!HouseholdCloudSharingService.indicatesLostAccess(CKError(.networkUnavailable)))
        #expect(!HouseholdCloudSharingService.indicatesLostAccess(CKError(.networkFailure)))
        #expect(!HouseholdCloudSharingService.indicatesLostAccess(CKError(.serviceUnavailable)))
        #expect(!HouseholdCloudSharingService.indicatesLostAccess(CKError(.notAuthenticated)))
        #expect(!HouseholdCloudSharingService.indicatesLostAccess(HouseholdSharingError.cloudKitDidNotReturnRecord))
    }

    @Test func partialFailureMeansLostAccessOnlyWhenEveryItemSaysSo() {
        let share = CKRecord.ID(recordName: "share")
        let root = CKRecord.ID(recordName: "root")
        let allGone = CKError(.partialFailure, userInfo: [CKPartialErrorsByItemIDKey: [share: CKError(.zoneNotFound), root: CKError(.unknownItem)]])
        let mixed = CKError(.partialFailure, userInfo: [CKPartialErrorsByItemIDKey: [share: CKError(.zoneNotFound), root: CKError(.networkFailure)]])
        #expect(HouseholdCloudSharingService.indicatesLostAccess(allGone))
        #expect(!HouseholdCloudSharingService.indicatesLostAccess(mixed))
    }

    private func participant(role: MemberRole) -> HouseholdMember {
        let member = HouseholdMember(name: "Alex", role: role)
        member.cloudKitParticipantID = UUID().uuidString
        return member
    }

    #if canImport(UIKit)
    @Test func windowScenesUseCloudSharingDelegate() {
        let configuration = AppDelegate.sceneConfiguration(for: .windowApplication)
        #expect(configuration.delegateClass == MealPlanSceneDelegate.self)
    }
    #endif
}
