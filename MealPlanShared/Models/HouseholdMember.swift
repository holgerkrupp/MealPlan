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

    // Optional, explicitly entered food profile. Hard exclusions are kept
    // separate from soft preferences so a suggestion can explain its choice.
    var allergies: [String] = []
    var mustAvoidIngredients: [String] = []
    var dietaryPatterns: [String] = []
    var dislikes: [String] = []
    var favorites: [String] = []
    var preferredCuisines: [String] = []
    var spiceTolerance: Int?

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

/// Explainable, opt-in recipe compatibility checks. An empty profile never
/// filters anything, and soft preferences are returned as ranking signals
/// rather than hard exclusions.
struct FoodProfileMatch: Equatable, Sendable {
    var isAllowed: Bool
    var hardReasons: [String]
    var softMatches: [String]
}

enum FoodProfileMatcher {
    static func evaluate(dish: Dish, for member: HouseholdMember) -> FoodProfileMatch {
        let ingredientText = dish.sortedIngredients
            .map { $0.ingredient?.name ?? $0.rawText ?? "" }
            .joined(separator: " ")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let hardTerms = (member.allergies + member.mustAvoidIngredients)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        let hardHits = hardTerms.filter { ingredientText.localizedCaseInsensitiveContains($0) }
        let softTerms = (member.dislikes + member.favorites + member.preferredCuisines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let softHits = softTerms.filter { ingredientText.localizedCaseInsensitiveContains($0) || dish.name.localizedCaseInsensitiveContains($0) }
        return FoodProfileMatch(
            isAllowed: hardHits.isEmpty,
            hardReasons: hardHits.map { String(localized: "Contains \($0)") },
            softMatches: softHits
        )
    }

    static func allowedDishes(_ dishes: [Dish], for members: [HouseholdMember]) -> [Dish] {
        dishes.filter { dish in members.allSatisfy { evaluate(dish: dish, for: $0).isAllowed } }
    }
}
