import Testing
import Foundation
@testable import MealPlan

/// The pure parts of adding someone nearby. The MultipeerConnectivity
/// hand-off itself needs two real devices.
struct NearbyInviteTests {

    @Test func codesAreRandomAndSafeInAURL() {
        let first = NearbyInvite.makeCode()
        let second = NearbyInvite.makeCode()
        #expect(first != second)
        #expect(first.count == 22)
        #expect(first.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
    }

    @Test func hintRecognisesACodeWithoutBeingIt() {
        let code = NearbyInvite.makeCode()
        #expect(NearbyInvite.hint(for: code) == NearbyInvite.hint(for: code))
        #expect(NearbyInvite.hint(for: code) != NearbyInvite.hint(for: NearbyInvite.makeCode()))
        #expect(NearbyInvite.hint(for: code).count == 12)
        #expect(NearbyInvite.hint(for: code) != code)
    }

    /// `MCPeerID` traps on an empty name or one over 63 bytes of UTF-8.
    @Test func peerNamesFitMultipeerConnectivitysLimit() {
        #expect(NearbyInvite.peerDisplayName("  Alex  ") == "Alex")
        #expect(NearbyInvite.peerDisplayName(" ") == "MealPlan")
        let long = NearbyInvite.peerDisplayName(String(repeating: "👩‍🍳", count: 40))
        #expect(long.utf8.count <= 63)
        #expect(!long.isEmpty)
    }

    @Test func messagesSurviveTheTrip() {
        let messages: [NearbyInviteMessage] = [
            .joinRequest(code: "abc", userRecordName: "_0123abcd", name: "Alex"),
            .joinRequest(code: nil, userRecordName: "_0123abcd", name: "Alex"),
            .invitation(URL(string: "https://www.icloud.com/share/0abcDEF")!),
            .declined("That code has already been used."),
        ]
        for message in messages {
            #expect(NearbyInviteMessage(data: message.encoded()) == message)
        }
        #expect(NearbyInviteMessage(data: Data("nonsense".utf8)) == nil)
    }

    @Test func qrCodeLinksRoundTrip() {
        let code = NearbyInvite.makeCode()
        #expect(DeepLink(url: DeepLink.joinNearby(code: code).url) == .joinNearby(code: code))
        #expect(DeepLink(url: URL(string: "mealplan://join-nearby")!) == .joinNearby(code: nil))
        #expect(DeepLink(url: URL(string: "mealplan://join-nearby?code=")!) == .joinNearby(code: nil))
    }
}
