import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Where to send the user when only system Settings can fix Calendar access.
/// The only platform-specific part of the feature.
@MainActor
enum CalendarSystemSettings {
    static var url: URL? {
        #if os(iOS) || os(visionOS)
        URL(string: UIApplication.openSettingsURLString)
        #elseif os(macOS)
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")
        #else
        nil
        #endif
    }
}
