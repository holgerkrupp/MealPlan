import Foundation

/// The small, platform-neutral projection of one phone-owned cooking timer.
///
/// The watch never advances or persists this value as a second timer engine. It
/// derives the remaining time from `endDate` (or `pausedRemaining`) at render
/// time, which keeps a disconnected watch useful without sending per-second
/// updates over WatchConnectivity.
struct WatchCookingTimer: Codable, Hashable, Identifiable, Sendable {
    enum State: String, Codable, Hashable, Sendable {
        case running
        case paused
        case completed
    }

    var id: UUID
    var dishName: String
    var stepNumber: Int
    var stepText: String
    var label: String
    var duration: TimeInterval
    var endDate: Date
    var pausedRemaining: TimeInterval?

    func remaining(at date: Date) -> TimeInterval {
        max(0, pausedRemaining ?? endDate.timeIntervalSince(date))
    }

    func state(at date: Date) -> State {
        if pausedRemaining != nil { return .paused }
        return endDate <= date ? .completed : .running
    }

    var contextLabel: String {
        if stepNumber > 0 {
            return "\(dishName) · \(String(localized: "Step \(stepNumber)"))"
        }
        return dishName
    }
}

/// A point-in-time projection of the phone's `CookingSessionState.timers`.
/// `revision` is the session's persisted update timestamp and is used to
/// reject commands based on an older watch snapshot.
struct WatchCookingTimersSnapshot: Codable, Hashable, Sendable {
    var sessionID: UUID
    var revision: Date
    var timers: [WatchCookingTimer]

    var isEmpty: Bool { timers.isEmpty }
}

/// Actions the watch can ask the phone to perform. There is intentionally no
/// local mutation action: the phone owns the canonical timer state.
enum WatchCookingTimerAction: Codable, Hashable, Sendable {
    case pauseOrResume
    case cancel
}

/// A command is uniquely identified so a live-message retry followed by the
/// queued transfer path cannot apply the same action twice.
struct WatchCookingTimerCommand: Codable, Hashable, Sendable, Identifiable {
    var id: UUID
    var timerID: UUID
    var action: WatchCookingTimerAction
    var baseRevision: Date
    var issuedAt: Date

    init(
        id: UUID = UUID(),
        timerID: UUID,
        action: WatchCookingTimerAction,
        baseRevision: Date,
        issuedAt: Date = .now
    ) {
        self.id = id
        self.timerID = timerID
        self.action = action
        self.baseRevision = baseRevision
        self.issuedAt = issuedAt
    }
}

/// The phone sends this only after it has accepted or rejected a command.
/// The watch uses the acknowledgement—not message delivery—as the source of
/// truth for button success.
struct WatchCookingTimerCommandAcknowledgement: Codable, Hashable, Sendable {
    var commandID: UUID
    var timerID: UUID
    var accepted: Bool
    var message: String?
    var revision: Date?
}
