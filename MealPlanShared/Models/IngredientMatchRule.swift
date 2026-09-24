import Foundation
import SwiftData

/// A household decision about two ingredient descriptions that deterministic
/// matching cannot safely settle on its own.
enum IngredientMatchRuleKind: String, CaseIterable, Codable, Sendable {
    case alias
    case keepSeparate
}

@Model
final class IngredientMatchRule {
    var uuid: UUID = UUID()
    var modifiedAt: Date = Date.now
    /// `IngredientMatching.key(for:)`, stored in sorted order so a decision is
    /// independent of which spelling the user saw first.
    var leftKey: String = ""
    var rightKey: String = ""
    var kindRaw: String = IngredientMatchRuleKind.alias.rawValue
    var household: Household?

    init(leftName: String = "", rightName: String = "", kind: IngredientMatchRuleKind = .alias) {
        let keys = [IngredientMatching.key(for: leftName), IngredientMatching.key(for: rightName)].sorted()
        self.leftKey = keys.first ?? ""
        self.rightKey = keys.dropFirst().first ?? ""
        self.kindRaw = kind.rawValue
    }

    var kind: IngredientMatchRuleKind {
        get { IngredientMatchRuleKind(rawValue: kindRaw) ?? .alias }
        set { kindRaw = newValue.rawValue }
    }

    func applies(to firstKey: String, and secondKey: String) -> Bool {
        let keys = [firstKey, secondKey].sorted()
        return keys == [leftKey, rightKey]
    }
}
