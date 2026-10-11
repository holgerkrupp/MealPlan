import Foundation
import Observation
import SwiftData

/// The access state the app is allowed to use locally. CloudKit remains the
/// authority; this value is a durable, offline-safe projection of the last
/// known `CKShare.currentUserParticipant`.
enum HouseholdCollaborationRole: String, Codable, Sendable, CaseIterable {
    case owner
    case editor
    case viewOnly

    var canEdit: Bool { self != .viewOnly }
    var isOwner: Bool { self == .owner }

    static func initial(locator: HouseholdShareLocator) -> Self {
        locator.isOwner ? .owner : (locator.isReadOnly ? .viewOnly : .editor)
    }
}

/// A deliberately small App Group value. It is not another source of
/// membership truth: it only makes the last known safe state available before
/// the main app can refresh the share, and to processes which must never open
/// a CKSyncEngine (the Share Extension and widgets).
struct HouseholdCollaborationSnapshot: Codable, Equatable, Sendable {
    static let formatVersion = 1

    var formatVersion: Int = Self.formatVersion
    var householdID: UUID
    var role: HouseholdCollaborationRole
    var memberID: UUID?
    var participantID: String?
    var displayName: String
    var updatedAt: Date

    init(
        householdID: UUID,
        role: HouseholdCollaborationRole,
        memberID: UUID? = nil,
        participantID: String? = nil,
        displayName: String = HouseholdIdentityFallback.name,
        updatedAt: Date = .now
    ) {
        self.householdID = householdID
        self.role = role
        self.memberID = memberID
        self.participantID = participantID
        self.displayName = displayName
        self.updatedAt = updatedAt
    }
}

/// Versioned, monotonic App Group migration marker for collaboration metadata.
/// It intentionally has no CloudKit side effects. A missing or interrupted
/// marker is treated as "rescan needed", never as evidence that data is clean.
struct HouseholdCollaborationMigrationEnvelope: Codable, Equatable, Sendable {
    static let currentVersion = 1
    var version: Int
    var completedAt: Date
}

enum HouseholdCollaborationMigration {
    private static let key = "HouseholdCollaborationMigration.envelope"

    /// Returns false for a format written by a newer app. Callers then retain
    /// the conservative locator-derived state and do not overwrite the marker.
    @MainActor
    static func migrateIfNeeded(defaults: UserDefaults = HouseholdCollaborationStore.defaults) -> Bool {
        guard let data = defaults.data(forKey: key) else {
            let envelope = HouseholdCollaborationMigrationEnvelope(
                version: HouseholdCollaborationMigrationEnvelope.currentVersion,
                completedAt: .now
            )
            // A single small replacement is restart-safe: no existing sync
            // state is moved or deleted, and a crash merely repeats this write.
            defaults.set(try? JSONEncoder().encode(envelope), forKey: key)
            return true
        }
        guard let envelope = try? JSONDecoder().decode(HouseholdCollaborationMigrationEnvelope.self, from: data) else {
            // Corrupt sidecar metadata must never make a household writable.
            return false
        }
        guard envelope.version <= HouseholdCollaborationMigrationEnvelope.currentVersion else { return false }
        if envelope.version < HouseholdCollaborationMigrationEnvelope.currentVersion {
            let upgraded = HouseholdCollaborationMigrationEnvelope(
                version: HouseholdCollaborationMigrationEnvelope.currentVersion,
                completedAt: .now
            )
            defaults.set(try? JSONEncoder().encode(upgraded), forKey: key)
        }
        return true
    }

    static func supportsCurrentOrOlderFormat(defaults: UserDefaults = HouseholdCollaborationStore.defaults) -> Bool {
        guard let data = defaults.data(forKey: key) else { return true }
        guard let envelope = try? JSONDecoder().decode(HouseholdCollaborationMigrationEnvelope.self, from: data) else { return false }
        return envelope.version <= HouseholdCollaborationMigrationEnvelope.currentVersion
    }
}

enum HouseholdCollaborationStore {
    static var defaults: UserDefaults { UserDefaults(suiteName: SharedStore.appGroupID) ?? .standard }

    private static func key(_ householdID: UUID) -> String {
        "HouseholdCollaboration.snapshot.\(householdID.uuidString)"
    }

    static func load(for householdID: UUID, defaults: UserDefaults = defaults) -> HouseholdCollaborationSnapshot? {
        guard let data = defaults.data(forKey: key(householdID)),
              let snapshot = try? JSONDecoder().decode(HouseholdCollaborationSnapshot.self, from: data),
              snapshot.formatVersion == HouseholdCollaborationSnapshot.formatVersion,
              snapshot.householdID == householdID else { return nil }
        return snapshot
    }

    static func store(_ snapshot: HouseholdCollaborationSnapshot, defaults: UserDefaults = defaults) {
        defaults.set(try? JSONEncoder().encode(snapshot), forKey: key(snapshot.householdID))
    }

    /// The extension uses this to decide whether it may commit a shared write.
    /// Pre-session installs already have the locator's read-only bit, so a
    /// missing sidecar preserves their editable workflow while still denying a
    /// known view-only participant. The main app seeds the richer cache at its
    /// first bootstrap/refresh.
    static func canMutate(_ household: Household?) -> Bool {
        guard HouseholdCollaborationMigration.supportsCurrentOrOlderFormat() else { return false }
        guard let household else { return true }
        let locator = HouseholdShareLocator.decode(household.cloudKitShareIdentifier) ?? .solo(householdID: household.uuid)
        if locator.shareRecordName == nil { return true }
        if locator.isReadOnly { return false }
        return load(for: household.uuid)?.role.canEdit ?? true
    }
}

/// Bumps an App Group generation after a process commits local household data.
/// Only the main app observes the value and drives CKSyncEngine; extensions
/// only write this tiny sidecar value.
enum HouseholdStoreGeneration {
    private static let key = "HouseholdStoreGeneration.v1"

    static func value(defaults: UserDefaults = HouseholdCollaborationStore.defaults) -> UInt64 {
        (defaults.object(forKey: key) as? NSNumber)?.uint64Value ?? 0
    }

    static func markDirty(defaults: UserDefaults = HouseholdCollaborationStore.defaults) {
        let next = value(defaults: defaults) &+ 1
        defaults.set(NSNumber(value: next), forKey: key)
    }
}

/// Privacy-safe rolling diagnostics for support and integration tests. It
/// contains identifiers/counts/state only — never recipe, ingredient, address,
/// or member-name content.
struct HouseholdSyncDiagnostic: Codable, Equatable, Sendable {
    var event: String
    var at: Date
    var zoneName: String
    var databaseScope: String
    var role: HouseholdCollaborationRole
    var pendingCount: Int
}

enum HouseholdSyncDiagnostics {
    private static let key = "HouseholdSyncDiagnostics.v1"
    private static let limit = 40

    static func record(
        event: String,
        locator: HouseholdShareLocator,
        pendingCount: Int = 0,
        defaults: UserDefaults = HouseholdCollaborationStore.defaults
    ) {
        var entries = (defaults.data(forKey: key)).flatMap {
            try? JSONDecoder().decode([HouseholdSyncDiagnostic].self, from: $0)
        } ?? []
        entries.append(.init(
            event: event,
            at: .now,
            zoneName: locator.zoneName,
            databaseScope: locator.isOwner ? "private" : "shared",
            role: .initial(locator: locator),
            pendingCount: pendingCount
        ))
        if entries.count > limit { entries.removeFirst(entries.count - limit) }
        defaults.set(try? JSONEncoder().encode(entries), forKey: key)
    }

    static func recent(defaults: UserDefaults = HouseholdCollaborationStore.defaults) -> [HouseholdSyncDiagnostic] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([HouseholdSyncDiagnostic].self, from: data)) ?? []
    }
}

/// The one app-facing collaboration source of truth. `AppState` owns this
/// observable object; all legacy `isGuest` reads route through it while the UI
/// is progressively migrated to the clearer `canEdit`/`role` names.
@Observable
@MainActor
final class HouseholdCollaborationSession {
    private(set) var snapshot: HouseholdCollaborationSnapshot?

    var role: HouseholdCollaborationRole { snapshot?.role ?? .owner }
    private(set) var isMigrationCompatible = true
    var canEdit: Bool { isMigrationCompatible && role.canEdit }
    var isOwner: Bool { role.isOwner }
    var isViewOnly: Bool { !canEdit }
    var currentMemberID: UUID? { snapshot?.memberID }
    var currentParticipantID: String? { snapshot?.participantID }
    var currentMemberName: String { snapshot?.displayName ?? HouseholdIdentityFallback.name }

    func restore(for household: Household) {
        let locator = HouseholdShareLocator.decode(household.cloudKitShareIdentifier) ?? .solo(householdID: household.uuid)
        if let cached = HouseholdCollaborationStore.load(for: household.uuid) {
            // Never allow stale cached edit access to override a persisted
            // read-only locator. The inverse is safe: an editor cache may be
            // used while offline until the next share refresh.
            if locator.isReadOnly && cached.role != .viewOnly {
                apply(derivedSnapshot(for: household, role: .viewOnly))
            } else {
                snapshot = cached
            }
        } else {
            apply(derivedSnapshot(for: household, role: .initial(locator: locator)))
        }
    }

    func failClosedForUnknownMigrationFormat() {
        isMigrationCompatible = false
    }

    func reconcile(
        household: Household,
        role: HouseholdCollaborationRole,
        participantID: String? = nil,
        fallbackName: String? = nil
    ) {
        let member = participantID.flatMap { id in
            (household.members ?? []).first { $0.cloudKitParticipantID == id && $0.isActive }
        } ?? (household.members ?? []).first(where: { $0.isCurrentUser && $0.isActive })
        let name = member?.name ?? fallbackName ?? HouseholdIdentityFallback.name
        apply(.init(
            householdID: household.uuid,
            role: role,
            memberID: member?.uuid,
            participantID: participantID ?? member?.cloudKitParticipantID,
            displayName: name
        ))
    }

    func clear() { snapshot = nil }

    private func derivedSnapshot(for household: Household, role: HouseholdCollaborationRole) -> HouseholdCollaborationSnapshot {
        let current = (household.members ?? []).first { $0.isCurrentUser && $0.isActive }
        return .init(
            householdID: household.uuid,
            role: role,
            memberID: current?.uuid,
            participantID: current?.cloudKitParticipantID,
            displayName: current?.name ?? HouseholdIdentityFallback.name
        )
    }

    private func apply(_ snapshot: HouseholdCollaborationSnapshot) {
        self.snapshot = snapshot
        HouseholdCollaborationStore.store(snapshot)
    }
}

private enum HouseholdIdentityFallback {
    static var name: String { String(localized: "Me") }
}

enum HouseholdMutationAuthorization {
    /// The central non-UI check used by mutation services. It deliberately
    /// fails closed for a shared household without a session cache.
    static func canMutate(household: Household?) -> Bool {
        HouseholdCollaborationStore.canMutate(household)
    }
}

extension Notification.Name {
    /// Posted after a CloudKit push so the scene can refresh the share's
    /// current participant and roster, not merely its zone records.
    static let mealPlanCollaborationRefreshRequested = Notification.Name("de.holgerkrupp.mealplan.collaborationRefreshRequested")
}

/// Coalesces foreground, push, invitation and explicit refresh requests. It
/// intentionally delegates the actual transport to the existing sync service,
/// which retains its detached CKSyncEngine operation boundary.
@MainActor
final class HouseholdCollaborationRefreshCoordinator {
    static let shared = HouseholdCollaborationRefreshCoordinator()
    private var activeRefresh: Task<Void, Error>?

    private init() {}

    func refresh(
        household: Household,
        context: ModelContext,
        session: HouseholdCollaborationSession
    ) async throws {
        if let activeRefresh {
            return try await activeRefresh.value
        }
        let task = Task { @MainActor in
            try await HouseholdCloudSharingService.synchronize(
                household,
                context: context,
                session: session
            )
        }
        activeRefresh = task
        defer { activeRefresh = nil }
        try await task.value
    }
}
