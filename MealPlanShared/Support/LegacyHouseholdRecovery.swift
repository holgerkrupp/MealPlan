import Foundation

/// A small, content-free inventory of an old custom-sync household zone. It
/// deliberately contains identifiers and record counts only: it is safe to
/// retain in diagnostics and gives support enough information to distinguish
/// two independently-created households from an empty placeholder.
struct LegacyOwnedHouseholdSummary: Codable, Equatable, Sendable, Identifiable {
    let householdID: UUID
    let zoneName: String
    let shareRecordName: String?
    let isShared: Bool
    let dateCreated: Date
    /// Records that represent user content, excluding the root, members,
    /// default meal types, and deletion markers.
    let contentRecordCount: Int
    /// Latest server modification of user content. A previous reconciliation
    /// must be retried if an older installation writes to a competing zone.
    let lastContentModification: Date?

    var id: UUID { householdID }

    init(
        householdID: UUID,
        zoneName: String,
        shareRecordName: String? = nil,
        isShared: Bool,
        dateCreated: Date,
        contentRecordCount: Int,
        lastContentModification: Date? = nil
    ) {
        self.householdID = householdID
        self.zoneName = zoneName
        self.shareRecordName = shareRecordName
        self.isShared = isShared
        self.dateCreated = dateCreated
        self.contentRecordCount = contentRecordCount
        self.lastContentModification = lastContentModification
    }
}

/// Device-local proof that every then-visible competing zone was copied into
/// the canonical household. Source zones remain recoverable, but they no
/// longer keep prompting the user on every launch.
struct LegacyHouseholdReconciliationReceipt: Codable, Equatable {
    let canonicalHouseholdID: UUID
    let sources: [LegacyOwnedHouseholdSummary]

    func covers(localHouseholdID: UUID, owned: [LegacyOwnedHouseholdSummary]) -> Bool {
        guard localHouseholdID == canonicalHouseholdID else { return false }
        let current = owned.filter { $0.householdID != canonicalHouseholdID }
        return Set(current.map(\.householdID)) == Set(sources.map(\.householdID))
            && current.allSatisfy { candidate in
                sources.contains {
                    $0.householdID == candidate.householdID
                        && $0.zoneName == candidate.zoneName
                        && $0.contentRecordCount == candidate.contentRecordCount
                        && $0.lastContentModification == candidate.lastContentModification
                }
            }
    }
}

enum LegacyHouseholdReconciliationStore {
    private static let keyPrefix = "LegacyHouseholdReconciliation.v1"

    static func load(canonicalHouseholdID: UUID, defaults: UserDefaults = HouseholdCollaborationStore.defaults) -> LegacyHouseholdReconciliationReceipt? {
        let key = key(for: canonicalHouseholdID)
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(LegacyHouseholdReconciliationReceipt.self, from: data)
    }

    static func save(canonicalHouseholdID: UUID, owned: [LegacyOwnedHouseholdSummary], defaults: UserDefaults = HouseholdCollaborationStore.defaults) {
        let receipt = LegacyHouseholdReconciliationReceipt(
            canonicalHouseholdID: canonicalHouseholdID,
            sources: owned.filter { $0.householdID != canonicalHouseholdID }
        )
        defaults.set(try? JSONEncoder().encode(receipt), forKey: key(for: canonicalHouseholdID))
    }

    private static func key(for id: UUID) -> String {
        "\(keyPrefix).\(BuildEnvironment.cloudKit.rawValue).\(id.uuidString)"
    }
}

/// The local equivalent used while comparing a device's on-disk household to
/// the owned zones in CloudKit. Default meal slots and members are excluded so
/// a fresh install is still recognised as an empty placeholder.
struct LegacyLocalHouseholdSummary: Equatable, Sendable {
    let householdID: UUID
    let contentRecordCount: Int

    init(householdID: UUID, contentRecordCount: Int) {
        self.householdID = householdID
        self.contentRecordCount = contentRecordCount
    }

    @MainActor
    init(household: Household) {
        householdID = household.uuid
        contentRecordCount = (household.dishes?.count ?? 0)
            + (household.ingredients?.count ?? 0)
            + (household.entries?.count ?? 0)
            + (household.shoppingItems?.count ?? 0)
            + (household.cookedLogs?.count ?? 0)
            + (household.mealRoutines?.count ?? 0)
            + (household.weekTemplates?.count ?? 0)
            + (household.recipeFeeds?.count ?? 0)
            + (household.recipeBookmarks?.count ?? 0)
    }
}

/// A conservative decision for the legacy migration window. The plan is pure;
/// its reviewRequired case tells startup to copy populated zones before it
/// selects the canonical household. Recovery UI remains available on failure.
enum LegacyHouseholdRecoveryPlan: Equatable, Sendable {
    case noAction
    case adoptRemote(UUID)
    case reviewRequired(canonicalHouseholdID: UUID, competingHouseholdIDs: [UUID])

    static func make(
        local: LegacyLocalHouseholdSummary,
        owned: [LegacyOwnedHouseholdSummary]
    ) -> Self {
        let candidates = Dictionary(owned.map { ($0.householdID, $0) }, uniquingKeysWith: { first, _ in first })
            .values
            .sorted(by: canonicalComesFirst)
        guard let canonical = candidates.first else { return .noAction }

        let competing = candidates.filter { $0.householdID != canonical.householdID }
        let localMatchesCanonical = local.householdID == canonical.householdID

        // An empty device can adopt directly only when every other zone is
        // empty. Otherwise it must copy those zones into the canonical one.
        // Shared households win, then the oldest zone.
        if local.contentRecordCount == 0, !localMatchesCanonical,
           competing.allSatisfy({ $0.contentRecordCount == 0 }) {
            return .adoptRemote(canonical.householdID)
        }

        // A second empty zone is an inert placeholder. The current local zone
        // stays active if it is canonical, and nothing is silently discarded.
        if localMatchesCanonical,
           competing.allSatisfy({ $0.contentRecordCount == 0 }) {
            return .noAction
        }

        // Any populated non-canonical zone, or a populated local graph that
        // differs from the CloudKit canonical choice, is genuinely ambiguous.
        // Preserve both and surface the IDs/counts for an explicit recovery
        // path.
        if !localMatchesCanonical || competing.contains(where: { $0.contentRecordCount > 0 }) {
            let ids = Set(competing.map(\.householdID)).union([local.householdID])
            return .reviewRequired(
                canonicalHouseholdID: canonical.householdID,
                competingHouseholdIDs: ids.filter { $0 != canonical.householdID }.sorted { $0.uuidString < $1.uuidString }
            )
        }

        return .noAction
    }

    private static func canonicalComesFirst(_ lhs: LegacyOwnedHouseholdSummary, _ rhs: LegacyOwnedHouseholdSummary) -> Bool {
        if lhs.isShared != rhs.isShared { return lhs.isShared }
        if lhs.dateCreated != rhs.dateCreated { return lhs.dateCreated < rhs.dateCreated }
        return lhs.zoneName < rhs.zoneName
    }
}

/// Privacy-safe rolling records for legacy recovery and bounded invitation
/// failures. Recipe names, member data, addresses, and CloudKit payloads are
/// intentionally absent.
struct LegacyHouseholdDiagnostic: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    let event: String
    let at: Date
    let environment: String
    let activeHouseholdID: UUID?
    let ownedHouseholdIDs: [UUID]
    let errorCode: String?
}

enum LegacyHouseholdDiagnostics {
    private static let key = "LegacyHouseholdDiagnostics.v1"
    private static let limit = 40

    static func record(
        event: String,
        activeHouseholdID: UUID? = nil,
        owned: [LegacyOwnedHouseholdSummary] = [],
        error: Error? = nil,
        defaults: UserDefaults = HouseholdCollaborationStore.defaults
    ) {
        var entries = (defaults.data(forKey: key)).flatMap {
            try? JSONDecoder().decode([LegacyHouseholdDiagnostic].self, from: $0)
        } ?? []
        entries.append(.init(
            id: UUID(),
            event: event,
            at: .now,
            environment: BuildEnvironment.cloudKit.rawValue,
            activeHouseholdID: activeHouseholdID,
            ownedHouseholdIDs: owned.map(\.householdID).sorted { $0.uuidString < $1.uuidString },
            errorCode: error.map(errorCode)
        ))
        if entries.count > limit { entries.removeFirst(entries.count - limit) }
        defaults.set(try? JSONEncoder().encode(entries), forKey: key)
    }

    static func recent(defaults: UserDefaults = HouseholdCollaborationStore.defaults) -> [LegacyHouseholdDiagnostic] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([LegacyHouseholdDiagnostic].self, from: data)) ?? []
    }

    private static func errorCode(_ error: Error) -> String {
        let nsError = error as NSError
        return "\(nsError.domain):\(nsError.code)"
    }
}
