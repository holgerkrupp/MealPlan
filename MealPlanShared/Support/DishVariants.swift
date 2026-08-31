import Foundation
import SwiftData

/// Grouping several takes on the same dish — three burgers, two bolognese —
/// so they can live side by side instead of fighting the duplicate check.
///
/// A group is just a shared `variantGroupID` plus a name copied onto each
/// member. Every variant stays a full `Dish`: it can be planned, cooked and
/// shopped for on its own, and leaving a group takes nothing away from it.
enum DishVariants {

    /// A group of two or more dishes, ready for display.
    struct Group: Identifiable, Hashable {
        var id: UUID
        var name: String
        var dishUUIDs: [UUID]

        var count: Int { dishUUIDs.count }
    }

    /// Everything sharing this dish's group, the dish included, in display
    /// order. A dish with no group is its own single-element result.
    @MainActor
    static func members(of dish: Dish, in dishes: [Dish]) -> [Dish] {
        guard let groupID = dish.variantGroupID else { return [dish] }
        return sorted(dishes.filter { $0.variantGroupID == groupID })
    }

    /// The other dishes in this dish's group.
    @MainActor
    static func siblings(of dish: Dish, in dishes: [Dish]) -> [Dish] {
        members(of: dish, in: dishes).filter { $0 !== dish }
    }

    /// Groups keyed by identifier, skipping groups that ended up with a single
    /// member — a lone "variant" is just a dish, and showing it as a group
    /// would be a lie the user can't act on.
    @MainActor
    static func groups(in dishes: [Dish]) -> [UUID: [Dish]] {
        Dictionary(grouping: dishes.filter { $0.variantGroupID != nil }) { $0.variantGroupID! }
            .filter { $0.value.count > 1 }
            .mapValues(sorted)
    }

    /// Favourites first, then most-cooked, then alphabetical: the variant a
    /// household reaches for should lead its group.
    @MainActor
    static func sorted(_ dishes: [Dish]) -> [Dish] {
        dishes.sorted { lhs, rhs in
            if lhs.isFavorite != rhs.isFavorite { return lhs.isFavorite }
            if lhs.usageCount != rhs.usageCount { return lhs.usageCount > rhs.usageCount }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    /// Puts `dish` into `other`'s group, creating one if `other` has none. The
    /// group name defaults to the shared part of the two dish names, so
    /// "Smash Burger" + "Halloumi Burger" becomes a "Burger" group.
    @MainActor
    static func join(_ dish: Dish, with other: Dish, in dishes: [Dish] = []) {
        guard dish !== other else { return }
        if let groupID = other.variantGroupID {
            dish.variantGroupID = groupID
            dish.variantGroupName = other.variantGroupName
            return
        }
        let groupID = UUID()
        let name = sharedName(other.name, dish.name)
        other.variantGroupID = groupID
        other.variantGroupName = name
        dish.variantGroupID = groupID
        dish.variantGroupName = name
    }

    /// Takes a dish out of its group. When that would leave a single dish
    /// behind, the group is dissolved rather than kept as a group of one.
    @MainActor
    static func leaveGroup(_ dish: Dish, in dishes: [Dish]) {
        let remaining = siblings(of: dish, in: dishes)
        dish.variantGroupID = nil
        dish.variantGroupName = nil
        if remaining.count == 1 {
            remaining[0].variantGroupID = nil
            remaining[0].variantGroupName = nil
        }
    }

    /// Renames a group on every one of its members.
    @MainActor
    static func rename(groupOf dish: Dish, to newName: String, in dishes: [Dish]) {
        let cleaned = newName.trimmedCollapsed
        guard !cleaned.isEmpty else { return }
        for member in members(of: dish, in: dishes) {
            member.variantGroupName = cleaned
        }
    }

    /// The longest run of trailing words the two names share, which is what
    /// people usually name a group after ("Smash Burger" / "Veggie Burger" →
    /// "Burger"). Falls back to the first name when nothing lines up.
    static func sharedName(_ lhs: String, _ rhs: String) -> String {
        let left = lhs.trimmedCollapsed.components(separatedBy: " ").filter { !$0.isEmpty }
        let right = rhs.trimmedCollapsed.components(separatedBy: " ").filter { !$0.isEmpty }
        var shared: [String] = []
        for (l, r) in zip(left.reversed(), right.reversed()) {
            guard l.compare(r, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
            else { break }
            shared.insert(l, at: 0)
        }
        let joined = shared.joined(separator: " ")
        return joined.isEmpty ? lhs.trimmedCollapsed : joined
    }
}
