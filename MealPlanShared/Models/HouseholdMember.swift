import Foundation
import SwiftData

/// A cached view of a CloudKit share participant, so the app can show who is
/// in the household and attribute plans without hitting CloudKit each time.
@Model
final class HouseholdMember {
    var uuid: UUID = UUID()
    var modifiedAt: Date = Date.now
    /// Stable CloudKit identity used to reconcile share participants in place.
    var cloudKitParticipantID: String?
    var isActive: Bool = true
    var name: String = ""
    /// "owner", "editor" or "guest".
    var roleRaw: String = MemberRole.editor.rawValue
    var isCurrentUser: Bool = false
    var dateAdded: Date = Date.now

    var household: Household?

    init(name: String = "", role: MemberRole = .editor, isCurrentUser: Bool = false) {
        self.name = name
        self.roleRaw = role.rawValue
        self.isCurrentUser = isCurrentUser
        self.dateAdded = .now
    }

    var role: MemberRole {
        get { MemberRole(rawValue: roleRaw) ?? .editor }
        set { roleRaw = newValue.rawValue }
    }
}

enum MemberRole: String, CaseIterable, Identifiable, Codable, Sendable {
    case owner, editor, guest

    var id: String { rawValue }

    var localizedName: String {
        switch self {
        case .owner: String(localized: "Owner")
        case .editor: String(localized: "Can edit")
        case .guest: String(localized: "View only")
        }
    }
}
