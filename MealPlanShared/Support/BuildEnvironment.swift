import Foundation

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

    /// Read from the embedded provisioning profile: an explicit
    /// `com.apple.developer.icloud-container-environment` when the profile
    /// carries one, otherwise `get-task-allow`, which is true only for a
    /// development-signed build. A build with no profile at all is a simulator
    /// or unsigned build, which talks to Development.
    static let cloudKit: CloudKitEnvironment = {
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
        switch entitlements["com.apple.developer.icloud-container-environment"] {
        case let value as String:
            return CloudKitEnvironment(rawValue: value) ?? .unknown
        case let values as [String] where values.count == 1:
            return CloudKitEnvironment(rawValue: values[0]) ?? .unknown
        default:
            break
        }
        if let debuggable = entitlements["get-task-allow"] as? Bool {
            return debuggable ? .development : .production
        }
        return .unknown
    }()

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
