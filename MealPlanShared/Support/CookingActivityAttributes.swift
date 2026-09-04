#if canImport(ActivityKit) && os(iOS)
import ActivityKit
import Foundation

struct CookingActivityTimer: Codable, Hashable, Sendable, Identifiable {
    var id: UUID
    var contextLabel: String
    var timerLabel: String
    var endDate: Date
    var pausedRemaining: TimeInterval?
}

struct CookingActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// ActivityKit content is size-limited. Four simultaneous timers are
        /// enough to remain useful while keeping updates comfortably small.
        var timers: [CookingActivityTimer]
    }

    var sessionID: UUID
}
#endif
