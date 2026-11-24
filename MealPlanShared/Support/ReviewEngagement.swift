import Foundation

#if canImport(Darwin)
import Darwin
#endif

/// The only planning operations that may contribute to local App Store review
/// eligibility. This is deliberately separate from the meal data model: the
/// ledger describes this installation's use of the app, not household data.
enum ReviewPlacementSource: String, Codable, Sendable {
    /// One explicit placement made through the normal planning workflow,
    /// including Share & Plan and App Intents.
    case direct
    /// A copy, routine, recurring, or template operation. Bulk operations do
    /// not manufacture ten engagement events from one user action.
    case bulk
    /// A recipe/archive import that happens to include a plan.
    case imported
    case synchronized
    case migration
    case sample
}

struct ReviewEngagementState: Codable, Equatable, Sendable {
    static let currentVersion = 1
    static let eventLedgerLimit = 512
    static let empty = ReviewEngagementState()

    var version = currentVersion
    var successfulPlacementCount = 0
    var firstQualifyingActionAt: Date?
    var latestQualifyingActionAt: Date?
    var activeWeekKeys: [String] = []
    /// A bounded ledger prevents the local file from growing with the meal
    /// plan. Event IDs are entry UUIDs for direct placements.
    var seenEventIDs: [String] = []
    var pendingRequest = false
    var lastPromptAttemptAt: Date?
    var lastPromptAttemptVersion: String?

    mutating func normalize() {
        version = Self.currentVersion
        successfulPlacementCount = max(0, successfulPlacementCount)
        activeWeekKeys = Array(Set(activeWeekKeys)).sorted()
        seenEventIDs = Array(Set(seenEventIDs.suffix(Self.eventLedgerLimit)))
    }
}

/// Pure policy for the issue's three independent eligibility gates.
struct ReviewEligibilityPolicy: Sendable {
    static let standard = ReviewEligibilityPolicy()

    var requiredPlacements = 10
    var requiredCalendarWeeks = 3
    var minimumElapsedTime: TimeInterval = 14 * 24 * 60 * 60

    func isEligible(_ state: ReviewEngagementState) -> Bool {
        guard state.successfulPlacementCount >= requiredPlacements,
              state.activeWeekKeys.count >= requiredCalendarWeeks,
              let first = state.firstQualifyingActionAt,
              let latest = state.latestQualifyingActionAt
        else { return false }
        return latest.timeIntervalSince(first) >= minimumElapsedTime
    }

    func canAttempt(
        _ state: ReviewEngagementState,
        at now: Date,
        appVersion: String,
        cooldown: TimeInterval
    ) -> Bool {
        guard isEligible(state) else { return false }
        if state.lastPromptAttemptVersion == appVersion { return false }
        if let lastAttempt = state.lastPromptAttemptAt,
           now.timeIntervalSince(lastAttempt) < cooldown {
            return false
        }
        return true
    }

    func weekKey(for date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents(
            [.era, .yearForWeekOfYear, .weekOfYear],
            from: date
        )
        return "\(components.era ?? 1)-\(components.yearForWeekOfYear ?? 0)-\(components.weekOfYear ?? 0)"
    }
}

protocol ReviewEngagementPersistence {
    func load() throws -> ReviewEngagementState
    @discardableResult
    func update(
        _ body: (inout ReviewEngagementState) throws -> Void
    ) throws -> ReviewEngagementState
}

enum ReviewEngagementPersistenceError: Error {
    case couldNotOpenLockFile
    case couldNotLockFile
}

/// File-backed persistence used by the app and Share Extension. A POSIX file
/// lock protects the complete read/modify/write transaction, so two processes
/// cannot overwrite each other's placement event. The JSON file contains no
/// recipe names, dates of meals, or household records.
final class ReviewEngagementFilePersistence: ReviewEngagementPersistence {
    private let fileURL: URL
    private let lockURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(fileURL: URL? = nil) {
        let resolvedURL: URL
        if let fileURL {
            resolvedURL = fileURL
        } else if let group = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: SharedStore.appGroupID
        ) {
            resolvedURL = group.appending(path: "ReviewEngagement.json")
        } else {
            resolvedURL = URL.applicationSupportDirectory.appending(path: "ReviewEngagement.json")
        }
        self.fileURL = resolvedURL
        self.lockURL = resolvedURL.appendingPathExtension("lock")
    }

    func load() throws -> ReviewEngagementState {
        try withFileLock {
            try readUnlocked()
        }
    }

    @discardableResult
    func update(
        _ body: (inout ReviewEngagementState) throws -> Void
    ) throws -> ReviewEngagementState {
        try withFileLock {
            var state = try readUnlocked()
            try body(&state)
            state.normalize()
            let data = try encoder.encode(state)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: .atomic)
            return state
        }
    }

    private func readUnlocked() throws -> ReviewEngagementState {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return .empty
        }
        let data = try Data(contentsOf: fileURL)
        guard !data.isEmpty else { return .empty }
        return (try? decoder.decode(ReviewEngagementState.self, from: data)) ?? .empty
    }

    private func withFileLock<T>(_ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(
            at: lockURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        #if canImport(Darwin)
        let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw ReviewEngagementPersistenceError.couldNotOpenLockFile }
        guard Darwin.lockf(descriptor, F_LOCK, 0) == 0 else {
            Darwin.close(descriptor)
            throw ReviewEngagementPersistenceError.couldNotLockFile
        }
        defer {
            Darwin.lockf(descriptor, F_ULOCK, 0)
            Darwin.close(descriptor)
        }
        return try body()
        #else
        return try body()
        #endif
    }
}

/// In-memory persistence for deterministic unit tests and previews.
final class InMemoryReviewEngagementPersistence: ReviewEngagementPersistence {
    private(set) var state: ReviewEngagementState
    var updateError: Error?

    init(state: ReviewEngagementState = .empty) {
        self.state = state
    }

    func load() throws -> ReviewEngagementState { state }

    @discardableResult
    func update(
        _ body: (inout ReviewEngagementState) throws -> Void
    ) throws -> ReviewEngagementState {
        if let updateError { throw updateError }
        try body(&state)
        state.normalize()
        return state
    }
}

@MainActor
final class ReviewEngagementStore {
    static let eventLedgerLimit = ReviewEngagementState.eventLedgerLimit
    static let standardCooldown: TimeInterval = 365 * 24 * 60 * 60
    static let live = ReviewEngagementStore(persistence: ReviewEngagementFilePersistence())

    private let persistence: any ReviewEngagementPersistence
    private let policy: ReviewEligibilityPolicy
    private let now: () -> Date
    private let calendar: () -> Calendar

    init(
        persistence: any ReviewEngagementPersistence,
        policy: ReviewEligibilityPolicy = .standard,
        now: @escaping () -> Date = { .now },
        calendar: @escaping () -> Calendar = { .current }
    ) {
        self.persistence = persistence
        self.policy = policy
        self.now = now
        self.calendar = calendar
    }

    @discardableResult
    func recordSuccessfulPlacement(
        id: UUID,
        source: ReviewPlacementSource = .direct,
        at timestamp: Date? = nil
    ) -> Bool {
        guard source == .direct else { return false }
        let occurredAt = timestamp ?? now()
        do {
            var inserted = false
            _ = try persistence.update { state in
                let eventID = id.uuidString.lowercased()
                guard !state.seenEventIDs.contains(eventID) else { return }
                inserted = true
                state.seenEventIDs.append(eventID)
                if state.seenEventIDs.count > Self.eventLedgerLimit {
                    state.seenEventIDs.removeFirst(state.seenEventIDs.count - Self.eventLedgerLimit)
                }
                state.successfulPlacementCount += 1
                state.firstQualifyingActionAt = min(state.firstQualifyingActionAt ?? occurredAt, occurredAt)
                state.latestQualifyingActionAt = max(state.latestQualifyingActionAt ?? occurredAt, occurredAt)
                let key = policy.weekKey(for: occurredAt, calendar: calendar())
                if !state.activeWeekKeys.contains(key) { state.activeWeekKeys.append(key) }
                if policy.isEligible(state) { state.pendingRequest = true }
            }
            if inserted {
                NotificationCenter.default.post(name: .reviewEngagementDidChange, object: nil)
            }
            return inserted
        } catch {
            // Review tracking is strictly non-critical. A broken or locked
            // ledger must never make a meal placement fail.
            return false
        }
    }

    func snapshot() -> ReviewEngagementState {
        (try? persistence.load()) ?? .empty
    }

    @discardableResult
    func recordPromptAttempt(at timestamp: Date? = nil, appVersion: String) -> Bool {
        do {
            _ = try persistence.update { state in
                state.lastPromptAttemptAt = timestamp ?? now()
                state.lastPromptAttemptVersion = appVersion
                state.pendingRequest = false
            }
            return true
        } catch {
            return false
        }
    }
}

@MainActor
enum ReviewEngagementRecorder {
    static var store = ReviewEngagementStore.live

    static func recordSuccessfulPlacement(
        id: UUID,
        source: ReviewPlacementSource = .direct
    ) {
        _ = store.recordSuccessfulPlacement(id: id, source: source)
    }
}

extension Notification.Name {
    static let reviewEngagementDidChange = Notification.Name("MealPlan.reviewEngagementDidChange")
}
