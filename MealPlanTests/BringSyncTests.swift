import Testing
import Foundation
@testable import MealPlan

/// The half of the Bring! integration that can be pinned down: which changes a
/// sync decides on, and what goes out on the wire. The transport itself talks
/// to an API nobody publishes, so it is kept thin on purpose and exercised by
/// hand.
@MainActor
struct BringSyncTests {

    private func item(_ name: String, _ specification: String = "") -> BringSyncItem {
        BringSyncItem(name: name, specification: specification)
    }

    // MARK: - First sync

    @Test func firstSyncMergesBothListsRatherThanDeleting() {
        let plan = BringSyncPlan.make(
            local: [item("Joghurt", "500 g")],
            remote: [item("Bananen", "3")],
            shadow: []
        )
        #expect(plan.addToBring.map(\.name) == ["Joghurt"])
        #expect(plan.addLocally.map(\.name) == ["Bananen"])
        #expect(plan.removeFromBring.isEmpty)
        #expect(plan.checkOffLocally.isEmpty)
        #expect(plan.shadow.count == 2)
    }

    // MARK: - Removals need the shadow

    @Test func somethingTakenOffBringIsTickedOffHere() {
        let joghurt = item("Joghurt", "500 g")
        let plan = BringSyncPlan.make(
            local: [joghurt],
            remote: [],
            shadow: [joghurt.key]
        )
        #expect(plan.checkOffLocally == [joghurt])
        #expect(plan.addToBring.isEmpty)
        #expect(plan.shadow.isEmpty)
    }

    @Test func somethingTickedOffHereIsTakenOffBring() {
        let bananen = item("Bananen", "3")
        let plan = BringSyncPlan.make(
            local: [],
            remote: [bananen],
            shadow: [bananen.key]
        )
        #expect(plan.removeFromBring == [bananen])
        #expect(plan.addLocally.isEmpty)
        #expect(plan.shadow.isEmpty)
    }

    @Test func aSettledListNeedsNoChanges() {
        let joghurt = item("Joghurt", "500 g")
        let plan = BringSyncPlan.make(local: [joghurt], remote: [joghurt], shadow: [joghurt.key])
        #expect(plan.isEmpty)
        #expect(plan.shadow == [joghurt.key])
    }

    // MARK: - Amounts and spellings

    @Test func thePlansAmountWins() {
        let plan = BringSyncPlan.make(
            local: [item("Joghurt", "800 g")],
            remote: [item("Joghurt", "500 g")],
            shadow: [item("Joghurt").key]
        )
        #expect(plan.addToBring == [item("Joghurt", "800 g")])
        #expect(plan.checkOffLocally.isEmpty)
        #expect(plan.removeFromBring.isEmpty)
    }

    @Test func aDifferentSpellingIsNotASecondItem() {
        let plan = BringSyncPlan.make(
            local: [item("Joghurt", "500 g")],
            remote: [item("Jogurt", "500 g")],
            shadow: [item("Joghurt").key]
        )
        #expect(plan.isEmpty)
    }

    // MARK: - Pushing

    @Test func pushOnlySendsAndNeverRemoves() {
        let plan = BringSyncPlan.push(
            local: [item("Joghurt", "500 g")],
            remote: [item("Bananen", "3")]
        )
        #expect(plan.addToBring.map(\.name) == ["Joghurt"])
        #expect(plan.removeFromBring.isEmpty)
        #expect(plan.addLocally.isEmpty)
        #expect(plan.checkOffLocally.isEmpty)
        // Both sides are now known, so a later two-way sync doesn't read the
        // pushed items as "deleted in Bring!".
        #expect(plan.shadow.count == 2)
    }

    // MARK: - What goes on the wire

    @Test func changesCarryTheRightOperations() {
        var plan = BringSyncPlan()
        plan.addToBring = [item("Joghurt", "500 g")]
        plan.removeFromBring = [item("Bananen", "3")]

        let changes = plan.bringChanges
        #expect(changes.count == 2)
        #expect(changes[0] == BringChange(itemId: "Joghurt", spec: "500 g", operation: .purchase))
        #expect(changes[1] == BringChange(itemId: "Bananen", spec: "3", operation: .remove))
    }

    @Test func aChangeBatchEncodesTheWayBringExpects() throws {
        let batch = BringChangeBatch(changes: [
            BringChange(itemId: "Joghurt", spec: "500 g", operation: .purchase)
        ])
        let json = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(batch))
        let root = try #require(json as? [String: Any])
        let changes = try #require(root["changes"] as? [[String: Any]])

        #expect(root["sender"] as? String == "")
        #expect(changes.count == 1)
        #expect(changes[0]["itemId"] as? String == "Joghurt")
        #expect(changes[0]["spec"] as? String == "500 g")
        #expect(changes[0]["operation"] as? String == "TO_PURCHASE")
    }

    // MARK: - Requests

    @Test func signingInPostsTheCredentialsFormEncoded() throws {
        let request = BringAPI.logIn(email: "me@example.com", password: "hunter2&co")
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://api.getbring.com/rest/v2/bringauth")
        #expect(request.value(forHTTPHeaderField: "X-BRING-API-KEY") == BringAPI.apiKey)
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")

        let body = String(data: try #require(request.httpBody), encoding: .utf8)
        #expect(body == "email=me%40example.com&password=hunter2%26co")
        // Nothing is authorized yet, so no token may be attached.
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func signedInRequestsCarryTheSession() throws {
        let session = BringSession(
            userUUID: "user-1",
            publicUserUUID: "public-1",
            accessToken: "token-1",
            name: nil,
            email: nil
        )
        let lists = BringAPI.lists(session: session)
        #expect(lists.url?.absoluteString == "https://api.getbring.com/rest/bringusers/user-1/lists")
        #expect(lists.value(forHTTPHeaderField: "Authorization") == "Bearer token-1")
        #expect(lists.value(forHTTPHeaderField: "X-BRING-USER-UUID") == "user-1")

        let items = BringAPI.items(listUUID: "list-1", session: session)
        #expect(items.url?.absoluteString == "https://api.getbring.com/rest/v2/bringlists/list-1")

        let changes = try BringAPI.apply([], listUUID: "list-1", session: session)
        #expect(changes.httpMethod == "PUT")
        #expect(changes.url?.absoluteString == "https://api.getbring.com/rest/v2/bringlists/list-1/items")
    }

    // MARK: - Responses

    @Test func theListResponseDecodes() throws {
        let json = Data("""
        {"lists":[{"listUuid":"abc","name":"Zuhause","theme":"ch.publisheria.bring.theme.home"}]}
        """.utf8)
        let response = try JSONDecoder().decode(BringListsResponse.self, from: json)
        #expect(response.lists.map(\.name) == ["Zuhause"])
        #expect(response.lists.map(\.listUuid) == ["abc"])
    }

    /// The v2 shape nests the items; older answers don't. Both have to work —
    /// this is not an API anyone promises to keep still.
    @Test func bothShapesOfTheItemsResponseDecode() throws {
        let nested = Data("""
        {"uuid":"abc","status":"REGISTERED","items":{"purchase":[{"itemId":"Joghurt","specification":"500 g"}],"recently":[]}}
        """.utf8)
        #expect(try JSONDecoder().decode(BringItemsResponse.self, from: nested).purchase
                == [BringPurchase(itemId: "Joghurt", specification: "500 g")])

        let flat = Data("""
        {"uuid":"abc","purchase":[{"itemId":"Bananen","specification":""}],"recently":[]}
        """.utf8)
        #expect(try JSONDecoder().decode(BringItemsResponse.self, from: flat).purchase
                == [BringPurchase(itemId: "Bananen", specification: "")])
    }

    @Test func theSignInResponseDecodes() throws {
        let json = Data("""
        {"uuid":"user-1","publicUuid":"public-1","access_token":"token-1","refresh_token":"r","token_type":"Bearer","expires_in":604799,"name":"Holger","email":"me@example.com"}
        """.utf8)
        let session = try JSONDecoder().decode(BringSession.self, from: json)
        #expect(session.userUUID == "user-1")
        #expect(session.publicUserUUID == "public-1")
        #expect(session.accessToken == "token-1")
        #expect(session.name == "Holger")
    }
}
