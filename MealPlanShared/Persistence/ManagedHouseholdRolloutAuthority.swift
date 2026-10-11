import Foundation

enum ManagedHouseholdRolloutPhase: String, Codable, Sendable {
    case legacyActive
    case inventory
    case stagedCopy
    case verified
    case readyForCutover
    case managedActive
    case membersReinvited
    case legacyRecoveryOnly

    var usesManagedWriter: Bool {
        self == .managedActive || self == .membersReinvited
    }
}

/// These are explicit go/no-go facts, not inferred from a successful local
/// copy. Until every item is true, managed mirroring and invitations stay off.
struct ManagedHouseholdCutoverReadiness: Codable, Equatable, Sendable {
    var canonicalOwnerConfirmed = false
    var sameAccountHouseholdsConverged = false
    var lastLegacySnapshotStable = false
    var knownLegacyWritersResolved = false
    var appMutationPathReady = false
    var extensionsAndWidgetsReady = false
    var ownerConfirmed = false

    var missingRequirements: [String] {
        var missing: [String] = []
        if !canonicalOwnerConfirmed { missing.append("canonical-owner") }
        if !sameAccountHouseholdsConverged { missing.append("same-account-convergence") }
        if !lastLegacySnapshotStable { missing.append("legacy-snapshot") }
        if !knownLegacyWritersResolved { missing.append("legacy-writers") }
        if !appMutationPathReady { missing.append("app-mutation-path") }
        if !extensionsAndWidgetsReady { missing.append("dependent-clients") }
        if !ownerConfirmed { missing.append("owner-confirmation") }
        return missing
    }
}

/// Per-household authority written atomically in the App Group. It contains
/// only control metadata and a one-way source digest; user content stays in
/// the retained SwiftData store and the managed stores.
struct ManagedHouseholdRolloutRecord: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var version = currentVersion
    var householdID: UUID
    var environment: String
    var phase: ManagedHouseholdRolloutPhase = .legacyActive
    var sourceSnapshotFingerprint: String?
    var sourceGeneration: UInt64 = 0
    var managedWriteGeneration: UInt64 = 0
    var lateLegacyMutationCount: UInt64 = 0
    var reinviteNoticeDismissedAt: Date?
    var readiness = ManagedHouseholdCutoverReadiness()
    var updatedAt = Date.now

    init(householdID: UUID, environment: String) {
        self.householdID = householdID
        self.environment = environment
    }
}

enum ManagedHouseholdRolloutError: LocalizedError {
    case unsupportedVersion(Int)
    case invalidPhase(ManagedHouseholdRolloutPhase)
    case prerequisitesMissing([String])
    case managedWritesAlreadyAccepted
    case legacySyncUnavailable

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version): "A newer household rollout state format (\(version)) is present."
        case .invalidPhase(let phase): "The household cannot advance from the \(phase.rawValue) rollout phase."
        case .prerequisitesMissing: "Household cutover is waiting for its safety checks."
        case .managedWritesAlreadyAccepted: "The managed household already has writes and cannot return to a writable legacy store."
        case .legacySyncUnavailable: "The old household sync could not be safely drained before cutover."
        }
    }
}

@MainActor
final class ManagedHouseholdRolloutAuthority {
    static let shared = ManagedHouseholdRolloutAuthority()

    private let rootDirectory: URL

    init(rootDirectory: URL? = nil) {
        if let rootDirectory {
            self.rootDirectory = rootDirectory
        } else {
            let appGroup = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: SharedStore.appGroupID
            ) ?? URL.applicationSupportDirectory
            self.rootDirectory = appGroup.appending(
                path: "ManagedHouseholdRollout",
                directoryHint: .isDirectory
            )
        }
    }

    func record(for householdID: UUID) throws -> ManagedHouseholdRolloutRecord {
        let url = fileURL(for: householdID)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return ManagedHouseholdRolloutRecord(
                householdID: householdID,
                environment: BuildEnvironment.cloudKit.rawValue
            )
        }
        let record = try JSONDecoder().decode(ManagedHouseholdRolloutRecord.self, from: Data(contentsOf: url))
        guard record.version <= ManagedHouseholdRolloutRecord.currentVersion else {
            throw ManagedHouseholdRolloutError.unsupportedVersion(record.version)
        }
        guard record.householdID == householdID,
              record.environment == BuildEnvironment.cloudKit.rawValue else {
            throw ManagedHouseholdRolloutError.unsupportedVersion(record.version)
        }
        return record
    }

    func phase(for householdID: UUID) -> ManagedHouseholdRolloutPhase {
        (try? record(for: householdID).phase) ?? .legacyRecoveryOnly
    }

    func beginStaging(for householdID: UUID) throws {
        var record = try self.record(for: householdID)
        guard record.phase == .legacyActive || record.phase == .inventory || record.phase == .stagedCopy else {
            throw ManagedHouseholdRolloutError.invalidPhase(record.phase)
        }
        record.phase = .inventory
        record.sourceSnapshotFingerprint = nil
        record.sourceGeneration &+= 1
        record.readiness = ManagedHouseholdCutoverReadiness()
        try save(record)
    }

    func markStagedCopy(for householdID: UUID) throws {
        var record = try self.record(for: householdID)
        guard record.phase == .inventory || record.phase == .stagedCopy else {
            throw ManagedHouseholdRolloutError.invalidPhase(record.phase)
        }
        record.phase = .stagedCopy
        try save(record)
    }

    func markVerified(for householdID: UUID, sourceFingerprint: String) throws {
        var record = try self.record(for: householdID)
        guard record.phase == .stagedCopy || record.phase == .verified else {
            throw ManagedHouseholdRolloutError.invalidPhase(record.phase)
        }
        record.phase = .verified
        record.sourceSnapshotFingerprint = sourceFingerprint
        try save(record)
    }

    func markReadyForCutover(
        householdID: UUID,
        readiness: ManagedHouseholdCutoverReadiness
    ) throws {
        var record = try self.record(for: householdID)
        guard record.phase == .verified else {
            throw ManagedHouseholdRolloutError.invalidPhase(record.phase)
        }
        guard readiness.missingRequirements.isEmpty else {
            throw ManagedHouseholdRolloutError.prerequisitesMissing(readiness.missingRequirements)
        }
        record.readiness = readiness
        record.phase = .readyForCutover
        try save(record)
    }

    /// This is the sole transition that may open stores with CloudKit mirroring
    /// enabled. No current call site advances the phase automatically.
    func activateManagedWriter(for householdID: UUID) async throws {
        var record = try self.record(for: householdID)
        guard record.phase == .readyForCutover else {
            throw ManagedHouseholdRolloutError.invalidPhase(record.phase)
        }
        guard record.readiness.missingRequirements.isEmpty,
              record.sourceSnapshotFingerprint != nil else {
            throw ManagedHouseholdRolloutError.prerequisitesMissing(record.readiness.missingRequirements)
        }

        // Drain one final legacy sync and stop its local engine before the
        // new writer becomes authoritative. A fetch or save during that drain
        // may invalidate readiness, so reload the durable record afterwards.
        try await HouseholdRecordSyncService.shared.prepareForManagedCutover(householdID: householdID)
        record = try self.record(for: householdID)
        guard record.phase == .readyForCutover,
              record.readiness.missingRequirements.isEmpty,
              record.sourceSnapshotFingerprint != nil else {
            throw ManagedHouseholdRolloutError.prerequisitesMissing(record.readiness.missingRequirements)
        }
        record.phase = .managedActive
        try save(record)
    }

    func recordManagedWrite(for householdID: UUID) throws {
        var record = try self.record(for: householdID)
        guard record.phase == .managedActive || record.phase == .membersReinvited else {
            throw ManagedHouseholdRolloutError.invalidPhase(record.phase)
        }
        record.managedWriteGeneration &+= 1
        try save(record)
    }

    func markMembersReinvited(for householdID: UUID) throws {
        var record = try self.record(for: householdID)
        guard record.phase == .managedActive || record.phase == .membersReinvited else {
            throw ManagedHouseholdRolloutError.invalidPhase(record.phase)
        }
        record.phase = .membersReinvited
        try save(record)
    }

    func markReinviteNoticeDismissed(for householdID: UUID, at date: Date = .now) throws {
        var record = try self.record(for: householdID)
        guard record.phase == .managedActive || record.phase == .membersReinvited else {
            throw ManagedHouseholdRolloutError.invalidPhase(record.phase)
        }
        record.reinviteNoticeDismissedAt = date
        try save(record)
    }

    /// Any writes discovered in an old zone before cutover invalidate the
    /// verified baseline. After cutover they are recorded for recovery; the
    /// managed authority is never rolled back to a writable legacy transport.
    func noteLegacyMutation(for householdID: UUID) throws {
        var record = try self.record(for: householdID)
        if record.phase == .managedActive || record.phase == .membersReinvited {
            record.lateLegacyMutationCount &+= 1
        } else if record.phase == .verified || record.phase == .readyForCutover {
            record.phase = .stagedCopy
            record.sourceSnapshotFingerprint = nil
            record.readiness = ManagedHouseholdCutoverReadiness()
        }
        try save(record)
    }

    func usesManagedWriter(for householdID: UUID) -> Bool {
        phase(for: householdID).usesManagedWriter
    }

    /// The Share Extension and widgets are separate processes. They must be
    /// able to reject writes from the retired SwiftData path without opening
    /// the main app's actor-isolated rollout service.
    nonisolated static func usesManagedWriterInSharedContainer(for householdID: UUID) -> Bool {
        let root = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: SharedStore.appGroupID
        ) ?? URL.applicationSupportDirectory
        let url = root
            .appending(path: "ManagedHouseholdRollout", directoryHint: .isDirectory)
            .appending(path: BuildEnvironment.cloudKit.rawValue.lowercased(), directoryHint: .isDirectory)
            .appending(path: "\(householdID.uuidString).json")
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        guard let data = try? Data(contentsOf: url),
              let record = try? JSONDecoder().decode(ManagedHouseholdRolloutRecord.self, from: data),
              record.version <= ManagedHouseholdRolloutRecord.currentVersion,
              record.householdID == householdID,
              record.environment == BuildEnvironment.cloudKit.rawValue else {
            // An unreadable authority marker must not let an old extension
            // continue writing into a store that may already be retired.
            return true
        }
        return record.phase.usesManagedWriter
    }

    private func fileURL(for householdID: UUID) -> URL {
        rootDirectory
            .appending(path: BuildEnvironment.cloudKit.rawValue.lowercased(), directoryHint: .isDirectory)
            .appending(path: "\(householdID.uuidString).json")
    }

    private func save(_ record: ManagedHouseholdRolloutRecord) throws {
        try FileManager.default.createDirectory(at: fileURL(for: record.householdID).deletingLastPathComponent(), withIntermediateDirectories: true)
        var updated = record
        updated.updatedAt = .now
        try JSONEncoder().encode(updated).write(to: fileURL(for: updated.householdID), options: .atomic)
    }
}
