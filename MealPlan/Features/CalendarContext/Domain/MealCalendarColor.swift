import Foundation

/// A calendar's colour, as the user sees it in Calendar on iOS and macOS.
///
/// Stored as plain sRGB components rather than a `CGColor` or a SwiftUI `Color`
/// so the domain stays `Sendable`, `Equatable` and free of UI frameworks — the
/// conversion to something drawable happens in the view layer.
struct MealCalendarColor: Sendable, Equatable, Hashable, Codable {
    let red: Double
    let green: Double
    let blue: Double
    let alpha: Double

    init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        func clamp(_ value: Double) -> Double { min(max(value, 0), 1) }
        self.red = clamp(red)
        self.green = clamp(green)
        self.blue = clamp(blue)
        self.alpha = clamp(alpha)
    }
}
