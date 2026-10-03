import Foundation
#if canImport(UIKit)
import UIKit
#endif
#if os(iOS)
import Darwin
#endif

/// Semantic posture values consumed by the Fridge presentation. Keeping these
/// separate from the eventual hardware API makes the experience testable on a
/// simulator and keeps Duo-specific knowledge out of the rest of MealPlan.
enum FoldingPosture: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case closed
    case partiallyOpen
    case open
    case tabletop
    case unknown

    var id: String { rawValue }

    var localizedName: String {
        switch self {
        case .closed: String(localized: "Closed")
        case .partiallyOpen: String(localized: "Opening")
        case .open: String(localized: "Open")
        case .tabletop: String(localized: "Tabletop")
        case .unknown: String(localized: "Unknown")
        }
    }
}

struct FoldingDeviceState: Equatable, Sendable {
    var isFoldable: Bool
    var posture: FoldingPosture
    var hingeAngle: Double?

    static let unavailable = FoldingDeviceState(
        isFoldable: false,
        posture: .unknown,
        hingeAngle: nil
    )
}

/// The small seam where a future public Apple foldable-device API can be
/// adopted. Until the SDK exposes one, the production provider is deliberately
/// conservative and reports no foldable capability. Xcode previews, tests and
/// a launch argument can inject a Duo-like capability without private APIs.
enum FoldingDeviceStateProvider {
    static var current: FoldingDeviceState {
        // Xcode-Beta's iPhone Duo simulator and the corresponding hardware
        // expose the same machine identifier. Keeping this mapping here makes
        // it the only place that needs updating when Apple adds a new model or
        // publishes a higher-level posture API.
        if modelIdentifier == "iPhone19,4" {
            return FoldingDeviceState(isFoldable: true, posture: .unknown, hingeAngle: nil)
        }
        guard ProcessInfo.processInfo.environment["MEALPLAN_FRIDGE_FOLDABLE"] == "1" else {
            return .unavailable
        }
        return FoldingDeviceState(isFoldable: true, posture: .unknown, hingeAngle: nil)
    }

    private static var modelIdentifier: String? {
        if let simulator = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return simulator
        }
        #if os(iOS)
        var size = 0
        guard sysctlbyname("hw.machine", nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.machine", &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
        #else
        return nil
        #endif
    }
}

enum FridgeExperienceSettings {
    static let enabledKey = "fridgeExperience.enabled"
    static let simulatedFoldableKey = "fridgeExperience.simulatedFoldable"
    static let simulatedPostureKey = "fridgeExperience.simulatedPosture"

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }

    static var isSimulatedFoldable: Bool {
        UserDefaults.standard.bool(forKey: simulatedFoldableKey)
    }

    static var simulatedPosture: FoldingPosture {
        guard let raw = UserDefaults.standard.string(forKey: simulatedPostureKey),
              let posture = FoldingPosture(rawValue: raw)
        else { return .closed }
        return posture
    }

    static var isActive: Bool {
        isPhoneInterface && isEnabled && (FoldingDeviceStateProvider.current.isFoldable || isSimulatedFoldable)
    }

    static var isPhoneInterface: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .phone
        #else
        false
        #endif
    }
}
