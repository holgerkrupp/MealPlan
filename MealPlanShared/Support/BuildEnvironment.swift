import Foundation
#if os(macOS)
import Security
#endif

/// Which CloudKit environment a build's iCloud container talks to.
///
/// The two environments hold entirely separate records: nothing written by an
/// Xcode build is visible to a TestFlight or App Store build, and no API moves
/// records between them. Surfacing this in the app turns "why is my library
/// empty in TestFlight?" into something the user can see for themselves.
enum CloudKitEnvironment: String, Sendable {
    case development = "Development"
    case production = "Production"
    case unknown = "Unknown"

    var localizedName: String {
        switch self {
        case .development: String(localized: "Development")
        case .production: String(localized: "Production")
        case .unknown: String(localized: "Unknown")
        }
    }
}

enum BuildEnvironment {

    /// Prefer the signed CloudKit entitlement on macOS. When it is absent,
    /// infer the environment from the embedded profile's signing settings.
    static let cloudKit: CloudKitEnvironment = {
        // CloudKit selects its database from the entitlement in the signed
        // executable. A provisioning profile may allow both environments, and
        // the APNs entitlement describes a different service.
        #if os(macOS)
        if let environment = signedCloudKitEnvironment() {
            return environment
        }
        #endif

        // A simulator carries no profile at all, and a Mac app signed to run
        // locally often doesn't either — both talk to the development
        // environment, which is exactly what a debug build is.
        guard let entitlements = provisioningEntitlements() else {
            #if DEBUG
            return .development
            #else
            return .unknown
            #endif
        }
        if let debuggable = entitlements["get-task-allow"] as? Bool {
            return debuggable ? .development : .production
        }

        if let apsEnvironment = entitlements["com.apple.developer.aps-environment"] as? String {
            switch apsEnvironment {
            case "development": return .development
            case "production": return .production
            default: break
            }
        }

        switch entitlements["com.apple.developer.icloud-container-environment"] {
        case let value as String:
            return CloudKitEnvironment(rawValue: value) ?? .unknown
        case let values as [String]:
            // Xcode-managed profiles commonly advertise both environments;
            // without get-task-allow, Development is the only safe choice for
            // a locally signed profile that includes it.
            if values.contains(CloudKitEnvironment.development.rawValue) {
                return .development
            }
            if values.contains(CloudKitEnvironment.production.rawValue) {
                return .production
            }
            return .unknown
        default:
            break
        }
        return .unknown
    }()

    #if os(macOS)
    private static func signedCloudKitEnvironment() -> CloudKitEnvironment? {
        guard let task = SecTaskCreateFromSelf(nil),
              let key = CFStringCreateWithCString(
                  nil,
                  "com.apple.developer.icloud-container-environment",
                  CFStringBuiltInEncodings.UTF8.rawValue
              ),
              let value = SecTaskCopyValueForEntitlement(task, key, nil) as? String
        else { return nil }
        return CloudKitEnvironment(rawValue: value)
    }
    #endif

    private static var provisioningProfileURL: URL? {
        #if os(macOS)
        let url = Bundle.main.bundleURL.appending(path: "Contents/embedded.provisionprofile")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
        #else
        return Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision")
        #endif
    }

    /// The profile is a CMS-signed blob with an XML plist in the middle of it;
    /// slicing the plist out avoids linking Security just to read one key.
    private static func provisioningEntitlements() -> [String: Any]? {
        guard let url = provisioningProfileURL,
              let data = try? Data(contentsOf: url),
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(
                  of: Data("</plist>".utf8),
                  options: [],
                  in: start.upperBound..<data.endIndex
              )
        else { return nil }

        let plist = try? PropertyListSerialization.propertyList(
            from: data[start.lowerBound..<end.upperBound],
            options: [],
            format: nil
        )
        return (plist as? [String: Any])?["Entitlements"] as? [String: Any]
    }
}
