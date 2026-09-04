import Foundation

/// Talks to Bring!.
///
/// An actor because it holds the signed-in session: the UI can ask for a sync
/// from anywhere and only one of them will be re-authenticating at a time.
/// There is no refresh-token dance — when a call comes back unauthorized the
/// client signs in again with the keychain credentials and retries once, which
/// is both shorter and harder to get wrong.
actor BringClient {

    private let session: URLSession
    private var account: BringSession?

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// The signed-in account, if this client has one in hand.
    var currentAccount: BringSession? { account }

    func signOut() {
        account = nil
    }

    /// Sign in and keep the session. The credentials are the caller's to store.
    @discardableResult
    func signIn(email: String, password: String) async throws -> BringSession {
        let (data, response) = try await send(BringAPI.logIn(email: email, password: password))
        guard response.statusCode != 401, response.statusCode != 403 else {
            throw BringError.signInFailed
        }
        try check(response)
        let account = try decode(BringSession.self, from: data)
        self.account = account
        return account
    }

    func lists() async throws -> [BringList] {
        let data = try await authorized { BringAPI.lists(session: $0) }
        return try decode(BringListsResponse.self, from: data).lists
    }

    /// What is on the Bring! list right now, still to be bought.
    func purchases(in listUUID: String) async throws -> [BringPurchase] {
        let data = try await authorized { BringAPI.items(listUUID: listUUID, session: $0) }
        return try decode(BringItemsResponse.self, from: data).purchase
    }

    /// Send a batch of adds, tick-offs and removals. A no-op for an empty
    /// batch, so callers don't have to guard.
    func apply(_ changes: [BringChange], to listUUID: String) async throws {
        guard !changes.isEmpty else { return }
        _ = try await authorized { try BringAPI.apply(changes, listUUID: listUUID, session: $0) }
    }

    // MARK: - Details

    /// Run a request that needs a session, signing in again once if the token
    /// has gone stale — which it does silently, weeks after it was issued.
    private func authorized(
        _ build: (BringSession) throws -> URLRequest
    ) async throws -> Data {
        var account: BringSession
        if let existing = self.account {
            account = existing
        } else {
            account = try await signedInAccount()
        }
        var (data, response) = try await send(try build(account))

        if response.statusCode == 401 || response.statusCode == 403 {
            self.account = nil
            account = try await signedInAccount()
            (data, response) = try await send(try build(account))
        }
        try check(response)
        return data
    }

    private func signedInAccount() async throws -> BringSession {
        guard let credentials = BringCredentialStore.load() else { throw BringError.notConnected }
        return try await signIn(email: credentials.email, password: credentials.password)
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw BringError.unreadableResponse }
        return (data, http)
    }

    private func check(_ response: HTTPURLResponse) throws {
        guard (200..<300).contains(response.statusCode) else {
            throw BringError.server(response.statusCode)
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw BringError.unreadableResponse
        }
    }
}
