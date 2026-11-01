import Foundation
import Testing
@testable import MealPlan

struct HouseholdMemberRosterTests {
    private let householdID = UUID()
    private let me = HouseholdMemberRoster.Participant(id: "me", name: nil, role: .owner, isCurrentUser: true)
    private let partner = HouseholdMemberRoster.Participant(id: "partner", name: "Alex", role: .coOwner, isCurrentUser: false)

    private func row(_ name: String, id: String?, role: MemberRole = .editor, isCurrentUser: Bool = false) -> HouseholdMember {
        let member = HouseholdMember(name: name, role: role, isCurrentUser: isCurrentUser)
        member.cloudKitParticipantID = id
        return member
    }

    private func reconcile(_ rows: [HouseholdMember]) -> (kept: [HouseholdMember], deleted: [HouseholdMember]) {
        var kept = rows
        var deleted: [HouseholdMember] = []
        HouseholdMemberRoster.reconcile(
            participants: [me, partner],
            householdID: householdID,
            members: rows,
            insert: { kept.append($0) },
            delete: { doomed in
                deleted.append(doomed)
                kept.removeAll { $0 === doomed }
            }
        )
        return (kept, deleted)
    }

    @Test func twoDevicesCreateTheSameRecordForAParticipant() {
        #expect(HouseholdMemberRoster.stableUUID(householdID: householdID, participantID: "me")
            == HouseholdMemberRoster.stableUUID(householdID: householdID, participantID: "me"))
        #expect(HouseholdMemberRoster.stableUUID(householdID: householdID, participantID: "me")
            != HouseholdMemberRoster.stableUUID(householdID: householdID, participantID: "partner"))
    }

    @Test func screenshotCaseEndsWithOneRowPerPerson() {
        // One row with an ID and one restored without, for each person.
        let result = reconcile([
            row("Family member", id: "me", role: .owner, isCurrentUser: true),
            row("Family member", id: nil, role: .owner, isCurrentUser: true),
            row("Alex", id: "partner"),
            row("Alex", id: nil)
        ])
        #expect(result.kept.count == 2)
        #expect(result.deleted.count == 2)
        #expect(HouseholdMemberRoster.activeMembers(result.kept).count == 2)
        #expect(result.kept.filter(\.isCurrentUser).count == 1)
    }

    @Test func allDevicesKeepTheSameSurvivor() {
        let first = row("Alex", id: "partner")
        let second = row("Alex", id: "partner")
        let expected = first.uuid.uuidString < second.uuid.uuidString ? first : second
        #expect(reconcile([first, second]).kept.contains { $0 === expected })
        #expect(reconcile([second, first]).kept.contains { $0 === expected })
    }

    @Test func aDuplicatesFoodProfileSurvivesTheMerge() {
        let first = row("Alex", id: "partner")
        let second = row("Alex", id: "partner")
        let duplicate = first.uuid.uuidString > second.uuid.uuidString ? first : second
        duplicate.allergies = ["Peanuts"]
        let result = reconcile([first, second])
        let survivor = result.kept.first { $0.cloudKitParticipantID == "partner" }
        #expect(survivor?.allergies == ["Peanuts"])
    }

    @Test func anUnknownNameDoesNotReplaceAKnownOne() {
        let mine = row("Sam", id: "me", role: .owner, isCurrentUser: true)
        _ = reconcile([mine])
        #expect(mine.name == "Sam")
    }

    @Test func someoneNotInTheShareStopsBeingShownButKeepsTheirRow() {
        let former = row("Former", id: nil)
        let gone = row("Gone", id: "removed")
        let result = reconcile([former, gone])
        #expect(result.deleted.isEmpty)
        #expect(!former.isActive)
        #expect(!gone.isActive)
    }

    @Test func refreshingACleanRosterChangesNothing() {
        let mine = row("Sam", id: "me", role: .owner, isCurrentUser: true)
        let theirs = row("Alex", id: "partner", role: .coOwner)
        let stamp = Date(timeIntervalSince1970: 1_000)
        mine.modifiedAt = stamp
        theirs.modifiedAt = stamp
        let result = reconcile([mine, theirs])
        #expect(result.deleted.isEmpty)
        #expect(mine.modifiedAt == stamp)
        #expect(theirs.modifiedAt == stamp)
    }

    @Test func listShowsOneRowPerPersonBeforeReconcileHasRun() {
        let shown = HouseholdMemberRoster.activeMembers([
            row("Alex", id: "partner"),
            row("Alex", id: "partner"),
            row("Alex", id: nil)
        ])
        #expect(shown.count == 1)
    }

    @Test func aHouseholdWithoutShareRowsStillListsItsPeople() {
        #expect(HouseholdMemberRoster.activeMembers([row("Sam", id: nil)]).count == 1)
    }
}
