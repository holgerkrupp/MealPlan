import Foundation

/// The shapes and requests of the Bring! shopping-list service.
///
/// Bring! publishes no API. What is here is the private REST interface the
/// Bring! apps themselves use, in the form the community clients settled on —
/// the same one Home Assistant's integration talks to. That has two
/// consequences the rest of this code is built around: it can change without
/// notice, so every call fails softly and never blocks the local list; and it
/// needs the account's own email and password, which is why an account created
/// through "Sign in with Apple" or Google has to be given a password in the
/// Bring! app first.
///
/// Request building is kept here, apart from the transport, so it can be
/// checked without going near the network.
enum BringAPI {

    static let baseURL = URL(string: "https://api.getbring.com/rest/")!

    /// The key the Bring! apps send. Not a secret — it identifies the client,
    /// not the user — and every community client uses the same one.
    static let apiKey = "cof4Nc6D8saplXjE3h3HXqHH8m7VU2i1Gs0g85Sp"

    // MARK: - Requests

    static func logIn(email: String, password: String) -> URLRequest {
        var request = URLRequest(url: baseURL.appending(path: "v2/bringauth"))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(formEncoded(["email": email, "password": password]).utf8)
        applyClientHeaders(to: &request)
        return request
    }

    static func lists(session: BringSession) -> URLRequest {
        var request = URLRequest(url: baseURL.appending(path: "bringusers/\(session.userUUID)/lists"))
        applyClientHeaders(to: &request, session: session)
        return request
    }

    static func items(listUUID: String, session: BringSession) -> URLRequest {
        var request = URLRequest(url: baseURL.appending(path: "v2/bringlists/\(listUUID)"))
        applyClientHeaders(to: &request, session: session)
        return request
    }

    /// One PUT carries every add and removal of a sync, so a list of twenty
    /// items is one round trip rather than twenty.
    static func apply(
        _ changes: [BringChange],
        listUUID: String,
        session: BringSession
    ) throws -> URLRequest {
        var request = URLRequest(url: baseURL.appending(path: "v2/bringlists/\(listUUID)/items"))
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(BringChangeBatch(changes: changes))
        applyClientHeaders(to: &request, session: session)
        return request
    }

    // MARK: - Details

    private static func applyClientHeaders(to request: inout URLRequest, session: BringSession? = nil) {
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(apiKey, forHTTPHeaderField: "X-BRING-API-KEY")
        request.setValue("ios", forHTTPHeaderField: "X-BRING-CLIENT")
        request.setValue("bring", forHTTPHeaderField: "X-BRING-APPLICATION")
        request.setValue(countryCode, forHTTPHeaderField: "X-BRING-COUNTRY")
        if let session {
            request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue(session.userUUID, forHTTPHeaderField: "X-BRING-USER-UUID")
            request.setValue(session.publicUserUUID, forHTTPHeaderField: "X-BRING-PUBLIC-USER-UUID")
        }
    }

    /// Bring! sorts items into aisles per country, so it wants one. The
    /// device's region is the best guess available; Germany is the fallback.
    static var countryCode: String {
        Locale.current.region?.identifier ?? "DE"
    }

    private static func formEncoded(_ fields: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return fields
            .map { key, value in
                let encode = { (text: String) in
                    text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
                }
                return "\(encode(key))=\(encode(value))"
            }
            .sorted()
            .joined(separator: "&")
    }
}

// MARK: - What comes back

/// A signed-in Bring! account. Held in memory for as long as the app runs and
/// thrown away on sign-out; only the credentials are kept, in the keychain.
struct BringSession: Sendable, Equatable {
    var userUUID: String
    var publicUserUUID: String
    var accessToken: String
    var name: String?
    var email: String?
}

extension BringSession: Decodable {
    enum CodingKeys: String, CodingKey {
        case uuid
        case publicUuid
        case accessToken = "access_token"
        case name
        case email
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        userUUID = try container.decode(String.self, forKey: .uuid)
        publicUserUUID = try container.decodeIfPresent(String.self, forKey: .publicUuid) ?? ""
        accessToken = try container.decode(String.self, forKey: .accessToken)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        email = try container.decodeIfPresent(String.self, forKey: .email)
    }
}

/// One of the account's shopping lists.
struct BringList: Decodable, Sendable, Identifiable, Hashable {
    var listUuid: String
    var name: String

    var id: String { listUuid }
}

struct BringListsResponse: Decodable, Sendable {
    var lists: [BringList]
}

/// One line on a Bring! list. `itemId` is the name Bring! knows it by and the
/// handle every change is addressed to; `specification` is the free text
/// beside it, which is where the amount goes.
struct BringPurchase: Decodable, Sendable, Equatable {
    var itemId: String
    var specification: String?
}

/// The items on one list.
///
/// Decoded leniently: the v2 endpoint nests them under `items`, older
/// responses put `purchase` at the top level, and an unofficial API is not the
/// place to insist on one of them.
struct BringItemsResponse: Decodable, Sendable {
    var purchase: [BringPurchase]

    private enum CodingKeys: String, CodingKey {
        case items, purchase
    }

    private struct Items: Decodable {
        var purchase: [BringPurchase]?
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let items = try container.decodeIfPresent(Items.self, forKey: .items) {
            purchase = items.purchase ?? []
        } else {
            purchase = try container.decodeIfPresent([BringPurchase].self, forKey: .purchase) ?? []
        }
    }
}

// MARK: - What goes out

/// What a change does to an item on the list.
enum BringOperation: String, Encodable, Sendable {
    /// Put it on the list — also the way to change the amount beside one
    /// that's already there.
    case purchase = "TO_PURCHASE"
    /// Tick it off: Bring! moves it to "recently".
    case recently = "TO_RECENTLY"
    /// Take it off the list altogether.
    case remove = "REMOVE"
}

struct BringChange: Encodable, Sendable, Equatable {
    var itemId: String
    var spec: String
    var operation: BringOperation

    /// Bring! stamps changes with where they were made. MealPlan doesn't ask
    /// for the user's location to put milk on a list, so these stay zero — the
    /// same thing the other clients send.
    var accuracy = "0.0"
    var altitude = "0.0"
    var latitude = "0.0"
    var longitude = "0.0"

    init(itemId: String, spec: String, operation: BringOperation) {
        self.itemId = itemId
        self.spec = spec
        self.operation = operation
    }
}

struct BringChangeBatch: Encodable, Sendable {
    var changes: [BringChange]
    var sender = ""
}

// MARK: - Errors

enum BringError: LocalizedError, Equatable {
    case notConnected
    case signInFailed
    case noListChosen
    case server(Int)
    case unreadableResponse

    var errorDescription: String? {
        switch self {
        case .notConnected:
            String(localized: "MealPlan isn’t connected to Bring! yet.")
        case .signInFailed:
            String(localized: "Bring! didn’t accept that email and password. If you signed up with Apple or Google, set a password in the Bring! app first.")
        case .noListChosen:
            String(localized: "Pick which Bring! list to use first.")
        case .server(let status):
            String(localized: "Bring! answered with an error (\(status)). Please try again later.")
        case .unreadableResponse:
            String(localized: "Bring! sent something MealPlan couldn’t read. This can happen when Bring! changes their app.")
        }
    }
}
