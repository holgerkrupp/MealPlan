import Foundation
import Security

/// The Bring! account this device is signed in to.
struct BringCredentials: Codable, Sendable, Equatable {
    var email: String
    var password: String
}

/// Where the Bring! password lives: the keychain, and nowhere else.
///
/// Bring! has no OAuth for third parties, so signing in means holding the
/// account's real password and sending it to `api.getbring.com` — the same
/// thing the Bring! app does, but somebody else's password all the same. It is
/// never written to the model store, so it never reaches iCloud, a backup file
/// or a shared household; a family member on another device signs in there
/// themselves.
enum BringCredentialStore {

    private static let service = "de.holgerkrupp.mealplan.bring"
    private static let account = "account"

    static func save(_ credentials: BringCredentials) throws {
        let data = try JSONEncoder().encode(credentials)
        var query = baseQuery
        SecItemDelete(query as CFDictionary)
        query[kSecValueData as String] = data
        // The password is only ever needed while the app is being used, and
        // only on this device: no iCloud keychain, no access before the first
        // unlock after a restart.
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw BringKeychainError(status: status) }
    }

    static func load() -> BringCredentials? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return try? JSONDecoder().decode(BringCredentials.self, from: data)
    }

    static func clear() {
        SecItemDelete(baseQuery as CFDictionary)
    }

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

struct BringKeychainError: LocalizedError {
    var status: OSStatus

    var errorDescription: String? {
        let reason = SecCopyErrorMessageString(status, nil) as String? ?? "\(status)"
        return String(localized: "MealPlan couldn’t save the Bring! password to the keychain: \(reason)")
    }
}
