import CryptoKit
import Foundation

/// Keeps the cached `HouseholdMember` rows at one row per share participant.
///
/// The share is the only authority on who is in a household, but rows have
/// historically multiplied in two ways: each device inserted its own random
/// UUID for a participant it hadn't yet seen synced, and a restored backup
/// brings rows without a participant ID, which a refresh then couldn't match.
enum HouseholdMemberRoster {
    struct Participant: Equatable {
        var id: String
        /// `nil` when CloudKit doesn't reveal this person's name to this device.
        var name: String?
        var role: MemberRole
        var isCurrentUser: Bool
    }

    /// The same participant gets the same record on every device, so two
    /// devices refreshing before their first sync can't create two people.
    static func stableUUID(householdID: UUID, participantID: String) -> UUID {
        let digest = SHA256.hash(data: Data("\(householdID.uuidString)|\(participantID)".utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    static func isPlaceholderName(_ name: String) -> Bool {
        name.isEmpty || name == "Family member" || name == String(localized: "Family member")
    }

    /// The people to show. Mirrors what `reconcile` will leave behind, for the
    /// time before it has run and on devices whose deletions can't be saved.
    static func activeMembers(_ members: [HouseholdMember]) -> [HouseholdMember] {
        let active = members.filter(\.isActive)
        let identified = Dictionary(grouping: active.filter { $0.cloudKitParticipantID != nil }) { $0.cloudKitParticipantID ?? "" }
            .values
            .map(canonical)
        let people = identified.isEmpty ? active : identified
        return people.sorted {
            ($0.dateAdded, $0.uuid.uuidString) < ($1.dateAdded, $1.uuid.uuidString)
        }
    }

    /// Every device picks the same survivor, so they converge rather than
    /// each deleting the other's row.
    private static func canonical(_ group: [HouseholdMember]) -> HouseholdMember {
        group.min { $0.uuid.uuidString < $1.uuid.uuidString } ?? group[0]
    }

    static func reconcile(
        participants: [Participant],
        householdID: UUID,
        members: [HouseholdMember],
        now: Date = .now,
        insert: (HouseholdMember) -> Void,
        delete: (HouseholdMember) -> Void
    ) {
        adoptOrphans(in: members, participants: participants, now: now)
        var rows = mergeDuplicates(in: members, now: now, delete: delete)

        let participantIDs = Set(participants.map(\.id))
        for member in rows where member.cloudKitParticipantID.map({ !participantIDs.contains($0) }) == true {
            if member.isActive || member.isCurrentUser {
                member.isActive = false
                member.isCurrentUser = false
                touchMetadata(of: member, at: now)
            }
        }

        for participant in participants {
            let existing = rows.first { $0.cloudKitParticipantID == participant.id }
            let member = existing ?? {
                let value = HouseholdMember()
                value.uuid = stableUUID(householdID: householdID, participantID: participant.id)
                value.cloudKitParticipantID = participant.id
                insert(value)
                rows.append(value)
                return value
            }()
            // CloudKit often hides a name from one device that another can
            // see, so an unknown name must not overwrite a known one.
            let name = participant.name.flatMap { $0.isEmpty ? nil : $0 }
                ?? (isPlaceholderName(member.name) ? String(localized: "Family member") : member.name)
            if existing == nil || member.name != name || member.role != participant.role
                || member.isCurrentUser != participant.isCurrentUser || !member.isActive {
                member.name = name
                member.role = participant.role
                member.isCurrentUser = participant.isCurrentUser
                member.isActive = true
                touchMetadata(of: member, at: now)
            }
        }
    }

    /// Gives a row without a participant ID to the participant it describes.
    /// Anyone left over isn't in the share, so they stop being shown; the row
    /// stays because plans can still be attributed to them.
    private static func adoptOrphans(in members: [HouseholdMember], participants: [Participant], now: Date) {
        let orphans = members
            .filter { $0.cloudKitParticipantID == nil && $0.isActive }
            .sorted { $0.uuid.uuidString < $1.uuid.uuidString }
        for orphan in orphans {
            let match = participants.first { orphan.isCurrentUser && $0.isCurrentUser }
                ?? participants.first { orphan.role == .owner && $0.role == .owner }
                ?? participants.first { participant in
                    guard !isPlaceholderName(orphan.name) else { return false }
                    let known = [participant.name] + members
                        .filter { $0.cloudKitParticipantID == participant.id }
                        .map { Optional($0.name) }
                    return known.contains { $0?.caseInsensitiveCompare(orphan.name) == .orderedSame }
                }
            if let match {
                orphan.cloudKitParticipantID = match.id
            } else {
                orphan.isActive = false
                orphan.isCurrentUser = false
            }
            touchMetadata(of: orphan, at: now)
        }
    }

    private static func mergeDuplicates(
        in members: [HouseholdMember],
        now: Date,
        delete: (HouseholdMember) -> Void
    ) -> [HouseholdMember] {
        var remaining = members.filter { $0.cloudKitParticipantID == nil }
        for group in Dictionary(grouping: members.filter({ $0.cloudKitParticipantID != nil }), by: { $0.cloudKitParticipantID ?? "" }).values {
            let survivor = canonical(group)
            remaining.append(survivor)
            guard group.count > 1 else { continue }

            // The newest filled-in food profile wins; allergies typed into a
            // duplicate must not vanish with it.
            if let profile = group.filter(hasProfile).max(by: { $0.profileModifiedAt < $1.profileModifiedAt }),
               profile !== survivor {
                survivor.allergies = profile.allergies
                survivor.mustAvoidIngredients = profile.mustAvoidIngredients
                survivor.dietaryPatterns = profile.dietaryPatterns
                survivor.dislikes = profile.dislikes
                survivor.favorites = profile.favorites
                survivor.preferredCuisines = profile.preferredCuisines
                survivor.spiceTolerance = profile.spiceTolerance
                survivor.markProfileModified(at: now)
            }
            if isPlaceholderName(survivor.name), let named = group.first(where: { !isPlaceholderName($0.name) }) {
                survivor.name = named.name
            }
            survivor.dateAdded = group.map(\.dateAdded).min() ?? survivor.dateAdded
            survivor.isActive = group.contains(where: \.isActive)
            touchMetadata(of: survivor, at: now)
            for duplicate in group where duplicate !== survivor {
                delete(duplicate)
            }
        }
        return remaining
    }

    private static func hasProfile(_ member: HouseholdMember) -> Bool {
        !member.allergies.isEmpty || !member.mustAvoidIngredients.isEmpty || !member.dietaryPatterns.isEmpty
            || !member.dislikes.isEmpty || !member.favorites.isEmpty || !member.preferredCuisines.isEmpty
            || member.spiceTolerance != nil
    }

    private static func touchMetadata(of member: HouseholdMember, at date: Date) {
        member.shareMetadataModifiedAt = date
        member.modifiedAt = date
    }
}
