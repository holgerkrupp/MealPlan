import CloudKit
import CryptoKit
import Foundation
import MultipeerConnectivity
import Observation

/// Adding someone to the household while you're together, without knowing
/// their Apple Account's email address or phone number.
///
/// CloudKit's own single-use links (`oneTimeURLParticipant()`) need Apple's
/// restricted extended-share-access entitlement, so this pairs the two
/// devices directly instead. The invitee's device advertises itself over
/// MultipeerConnectivity (Wi-Fi / Bluetooth, no internet needed for the
/// hand-off); the owner's device browses, connects over an encrypted session,
/// receives the invitee's iCloud user record name, adds exactly that Apple
/// Account to the share, and sends the share link back.
///
/// The owner's QR code carries a random one-time `code`. The invitee's
/// device advertises only a hash of it (`hint`), which lets the owner's
/// device connect to it automatically; the code itself travels inside the
/// encrypted session and is replaced as soon as it has been used.
enum NearbyInvite {
    /// Bonjour service `_mealplan-join._tcp` / `._udp` (declared in Info.plist).
    static let serviceType = "mealplan-join"

    /// 128 random bits, base64url without padding — safe in a URL query.
    static func makeCode() -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<16).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// What the invitee advertises so the owner's device can recognise the
    /// device that scanned its code, without the code itself being visible to
    /// anyone else browsing nearby.
    static func hint(for code: String) -> String {
        SHA256.hash(data: Data(code.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    /// `MCPeerID` traps on a display name longer than 63 bytes of UTF-8, and
    /// on an empty one.
    static func peerDisplayName(_ name: String) -> String {
        var result = ""
        for character in name.trimmingCharacters(in: .whitespacesAndNewlines) {
            guard result.utf8.count + String(character).utf8.count <= 63 else { break }
            result.append(character)
        }
        return result.isEmpty ? "MealPlan" : result
    }
}

/// What the two devices say to each other once connected.
enum NearbyInviteMessage: Codable, Equatable, Sendable {
    /// Invitee → owner. `code` is the one from the scanned QR code, if any.
    case joinRequest(code: String?, userRecordName: String, name: String)
    /// Owner → invitee: the share link, now that their Apple Account is on it.
    case invitation(URL)
    /// Owner → invitee: why they couldn't be added.
    case declined(String)

    func encoded() -> Data {
        (try? JSONEncoder().encode(self)) ?? Data()
    }

    init?(data: Data) {
        guard let message = try? JSONDecoder().decode(Self.self, from: data) else { return nil }
        self = message
    }
}

/// Carries MultipeerConnectivity's objects from its delegate queues to the
/// main actor, where every use of them happens.
private struct Handoff<Value>: @unchecked Sendable {
    let value: Value
}

// MARK: - Owner

/// The household owner's side, run by `HouseholdSharingView` while it is open.
@MainActor
@Observable
final class NearbyInviteHost: NSObject {
    struct Guest: Identifiable {
        enum State: Equatable {
            case nearby
            case adding
            case added
            case failed(String)
        }

        let id: MCPeerID
        var name: String
        var state: State
    }

    private(set) var guests: [Guest] = []
    /// The single-use code the QR code carries.
    private(set) var code = NearbyInvite.makeCode()
    private(set) var problem: String?
    /// Adds the Apple Account with this iCloud user record name to the share
    /// and returns the link it can join with.
    @ObservationIgnored var addGuest: (@MainActor (String) async throws -> URL)?

    @ObservationIgnored private let peerID: MCPeerID
    @ObservationIgnored private let browser: MCNearbyServiceBrowser
    @ObservationIgnored private var sessions: [MCPeerID: MCSession] = [:]
    /// Devices the owner tapped Add on. Anyone else must present the code.
    @ObservationIgnored private var chosenByOwner: Set<MCPeerID> = []

    var codeURL: URL { DeepLink.joinNearby(code: code).url }

    init(displayName: String) {
        peerID = MCPeerID(displayName: NearbyInvite.peerDisplayName(displayName))
        browser = MCNearbyServiceBrowser(peer: peerID, serviceType: NearbyInvite.serviceType)
        super.init()
        browser.delegate = self
    }

    func start() {
        problem = nil
        browser.startBrowsingForPeers()
    }

    func stop() {
        browser.stopBrowsingForPeers()
        for session in sessions.values { session.disconnect() }
        sessions.removeAll()
    }

    func add(_ guest: Guest) {
        chosenByOwner.insert(guest.id)
        connect(to: guest.id)
    }

    private func connect(to peer: MCPeerID) {
        guard sessions[peer] == nil else { return }
        let session = MCSession(peer: peerID, securityIdentity: nil, encryptionPreference: .required)
        session.delegate = self
        sessions[peer] = session
        setState(.adding, for: peer)
        browser.invitePeer(peer, to: session, withContext: nil, timeout: 30)
    }

    private func found(_ peer: MCPeerID, info: [String: String]?) {
        let name = info?["name"] ?? peer.displayName
        if let index = guests.firstIndex(where: { $0.id == peer }) {
            guests[index].name = name
        } else {
            guests.append(Guest(id: peer, name: name, state: .nearby))
        }
        // This device scanned the current code: connect without waiting for
        // a tap. It still has to present the code itself once connected.
        if info?["hint"] == NearbyInvite.hint(for: code) {
            connect(to: peer)
        }
    }

    private func lost(_ peer: MCPeerID) {
        guests.removeAll { $0.id == peer && sessions[peer] == nil && $0.state != .added }
    }

    private func sessionChanged(_ peer: MCPeerID, to state: MCSessionState) {
        guard state == .notConnected, sessions[peer] != nil else { return }
        sessions[peer] = nil
        chosenByOwner.remove(peer)
        if guests.first(where: { $0.id == peer })?.state == .adding {
            setState(.failed(String(localized: "The connection was lost.")), for: peer)
        }
    }

    private func received(_ message: NearbyInviteMessage, from peer: MCPeerID) async {
        guard case .joinRequest(let presentedCode, let userRecordName, let name) = message,
              let session = sessions[peer] else { return }
        if let index = guests.firstIndex(where: { $0.id == peer }) {
            guests[index].name = name
        }

        let usedCode = presentedCode == code
        guard usedCode || chosenByOwner.contains(peer) else {
            send(.declined(String(localized: "That code has already been used. Ask for a new one.")), over: session, to: peer)
            setState(.nearby, for: peer)
            await hangUp(peer, session: session)
            return
        }
        // Single use: whoever comes next needs the new code on screen.
        if usedCode { code = NearbyInvite.makeCode() }

        do {
            guard let addGuest else { throw HouseholdSharingError.onlyOwnerCanInvite }
            let url = try await addGuest(userRecordName)
            send(.invitation(url), over: session, to: peer)
            setState(.added, for: peer)
        } catch {
            send(.declined(error.localizedDescription), over: session, to: peer)
            setState(.failed(error.localizedDescription), for: peer)
        }
        await hangUp(peer, session: session)
    }

    /// Leaves a moment for the last message to arrive before disconnecting.
    private func hangUp(_ peer: MCPeerID, session: MCSession) async {
        chosenByOwner.remove(peer)
        try? await Task.sleep(for: .seconds(3))
        if sessions[peer] === session { sessions[peer] = nil }
        session.disconnect()
    }

    private func send(_ message: NearbyInviteMessage, over session: MCSession, to peer: MCPeerID) {
        try? session.send(message.encoded(), toPeers: [peer], with: .reliable)
    }

    private func setState(_ state: Guest.State, for peer: MCPeerID) {
        guard let index = guests.firstIndex(where: { $0.id == peer }) else { return }
        guests[index].state = state
    }
}

extension NearbyInviteHost: MCNearbyServiceBrowserDelegate {
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        let peer = Handoff(value: peerID)
        Task { @MainActor in self.found(peer.value, info: info) }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        let peer = Handoff(value: peerID)
        Task { @MainActor in self.lost(peer.value) }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        Task { @MainActor in
            self.problem = String(localized: "MealPlan can’t look for nearby devices. Allow it to find devices on your local network in the Settings app, then reopen this screen.")
        }
    }
}

extension NearbyInviteHost: MCSessionDelegate {
    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        let peer = Handoff(value: peerID)
        Task { @MainActor in self.sessionChanged(peer.value, to: state) }
    }

    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        guard let message = NearbyInviteMessage(data: data) else { return }
        let peer = Handoff(value: peerID)
        Task { @MainActor in await self.received(message, from: peer.value) }
    }

    nonisolated func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    nonisolated func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    nonisolated func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}

// MARK: - Invitee

/// The invitee's side, run by `JoinNearbyHouseholdView`.
@MainActor
@Observable
final class NearbyInviteGuest: NSObject {
    enum State: Equatable {
        case preparing
        case waiting
        case connected
        case received(URL)
        case failed(String)
    }

    private(set) var state: State = .preparing
    /// The code from the owner's QR code, when this screen was opened by it.
    let code: String?

    @ObservationIgnored private var peerID: MCPeerID?
    @ObservationIgnored private var advertiser: MCNearbyServiceAdvertiser?
    @ObservationIgnored private var session: MCSession?
    @ObservationIgnored private var userRecordName = ""
    @ObservationIgnored private var name = ""

    init(code: String?) {
        self.code = code
    }

    func start(name: String) async {
        stop()
        state = .preparing
        self.name = NearbyInvite.peerDisplayName(name)
        do {
            userRecordName = try await CKContainer(identifier: SharedStore.cloudKitContainerID).userRecordID().recordName
        } catch let error as CKError where error.code == .notAuthenticated {
            state = .failed(String(localized: "Sign in to iCloud on this device to join a household."))
            return
        } catch {
            state = .failed(error.localizedDescription)
            return
        }

        let peerID = MCPeerID(displayName: self.name)
        var info = ["name": self.name]
        if let code { info["hint"] = NearbyInvite.hint(for: code) }
        let advertiser = MCNearbyServiceAdvertiser(peer: peerID, discoveryInfo: info, serviceType: NearbyInvite.serviceType)
        advertiser.delegate = self
        self.peerID = peerID
        self.advertiser = advertiser
        advertiser.startAdvertisingPeer()
        state = .waiting
    }

    func stop() {
        advertiser?.stopAdvertisingPeer()
        advertiser = nil
        session?.disconnect()
        session = nil
    }

    private func invited(reply: (Bool, MCSession?) -> Void) {
        guard session == nil, let peerID, state == .waiting else {
            reply(false, nil)
            return
        }
        let session = MCSession(peer: peerID, securityIdentity: nil, encryptionPreference: .required)
        session.delegate = self
        self.session = session
        reply(true, session)
    }

    private func sessionChanged(_ session: MCSession, peer: MCPeerID, to newState: MCSessionState) {
        guard session === self.session else { return }
        switch newState {
        case .connected:
            state = .connected
            let request = NearbyInviteMessage.joinRequest(code: code, userRecordName: userRecordName, name: name)
            try? session.send(request.encoded(), toPeers: [peer], with: .reliable)
        case .notConnected:
            self.session = nil
            // Still advertising: the owner can try again.
            if state == .connected { state = .waiting }
        default:
            break
        }
    }

    private func received(_ message: NearbyInviteMessage) {
        switch message {
        case .invitation(let url):
            state = .received(url)
            stop()
        case .declined(let reason):
            state = .failed(reason)
            stop()
        case .joinRequest:
            break
        }
    }
}

extension NearbyInviteGuest: MCNearbyServiceAdvertiserDelegate {
    nonisolated func advertiser(
        _ advertiser: MCNearbyServiceAdvertiser,
        didReceiveInvitationFromPeer peerID: MCPeerID,
        withContext context: Data?,
        invitationHandler: @escaping (Bool, MCSession?) -> Void
    ) {
        let reply = Handoff(value: invitationHandler)
        Task { @MainActor in self.invited(reply: reply.value) }
    }

    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        Task { @MainActor in
            self.state = .failed(String(localized: "MealPlan can’t be found by nearby devices. Allow it to find devices on your local network in the Settings app, then try again."))
        }
    }
}

extension NearbyInviteGuest: MCSessionDelegate {
    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        let objects = Handoff(value: (session, peerID))
        Task { @MainActor in self.sessionChanged(objects.value.0, peer: objects.value.1, to: state) }
    }

    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        guard let message = NearbyInviteMessage(data: data) else { return }
        Task { @MainActor in self.received(message) }
    }

    nonisolated func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    nonisolated func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    nonisolated func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}
