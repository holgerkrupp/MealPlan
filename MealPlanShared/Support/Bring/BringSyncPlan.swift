import Foundation

/// One line as both sides see it: the name Bring! files it under, and the
/// amount that goes beside it.
struct BringSyncItem: Sendable, Equatable {
    var name: String
    var specification: String

    init(name: String, specification: String = "") {
        self.name = name
        self.specification = specification
    }

    /// What decides whether two lines are the same thing — the same fold the
    /// shopping list uses, so "Joghurt" here and "Jogurt" in Bring! don't turn
    /// into two entries that keep re-adding each other.
    var key: String { IngredientMatching.key(for: name) }
}

/// What has to happen to bring the MealPlan list and the Bring! list back
/// together.
///
/// Two lists that both change need a memory of what they last agreed on,
/// otherwise "you added it here" and "they deleted it there" are the same
/// difference. That memory is the *shadow*: the keys that were on both lists
/// when they were last in step, kept on the household so every device that
/// syncs the same Bring! list reads the same history.
///
/// Everything here is a pure function of the three sets, so the interesting
/// half of the integration can be tested without a network — which matters for
/// an API nobody can promise will answer the same way tomorrow.
struct BringSyncPlan: Equatable, Sendable {
    /// Put these on the Bring! list (an add also updates an amount).
    var addToBring: [BringSyncItem] = []
    /// Take these off the Bring! list; named as Bring! knows them.
    var removeFromBring: [BringSyncItem] = []
    /// Put these on the MealPlan list.
    var addLocally: [BringSyncItem] = []
    /// Tick these off in MealPlan — somebody bought them and cleared them in
    /// Bring!.
    var checkOffLocally: [BringSyncItem] = []
    /// What both lists hold once this plan has been applied.
    var shadow: [String] = []

    var isEmpty: Bool {
        addToBring.isEmpty && removeFromBring.isEmpty
            && addLocally.isEmpty && checkOffLocally.isEmpty
    }

    /// Work out the two-way difference.
    ///
    /// - Parameters:
    ///   - local: the MealPlan lines still to buy (ticked-off ones are, to
    ///     this, gone).
    ///   - remote: what Bring! still has on the list.
    ///   - shadow: the keys the last sync left both lists agreeing on.
    ///
    /// Where both sides have a line but the amounts differ, MealPlan's wins:
    /// its amount is the one the plan just worked out from the recipes, and a
    /// hand-typed "2" in Bring! shouldn't survive a rebuild that says 500 g.
    static func make(
        local: [BringSyncItem],
        remote: [BringSyncItem],
        shadow: [String]
    ) -> BringSyncPlan {
        let locals = byKey(local)
        let remotes = byKey(remote)

        var plan = BringSyncPlan()
        var survivors: [String] = []

        for (key, item) in locals {
            if let onBring = counterpart(of: key, in: remotes) {
                // On both lists. Keep it, and correct the amount if Bring!'s
                // has drifted from what the plan says.
                if onBring.specification != item.specification {
                    plan.addToBring.append(item)
                }
                survivors.append(key)
            } else if knows(key, shadow) {
                // It was on both lists and Bring! no longer has it: bought.
                plan.checkOffLocally.append(item)
            } else {
                plan.addToBring.append(item)
                survivors.append(key)
            }
        }

        for (key, item) in remotes where counterpart(of: key, in: locals) == nil {
            if knows(key, shadow) {
                // Ticked off or cleared in MealPlan since the last sync.
                plan.removeFromBring.append(item)
            } else {
                plan.addLocally.append(item)
                survivors.append(key)
            }
        }

        // Stable order, so a plan reads the same twice and can be compared.
        plan.addToBring.sort { $0.key < $1.key }
        plan.removeFromBring.sort { $0.key < $1.key }
        plan.addLocally.sort { $0.key < $1.key }
        plan.checkOffLocally.sort { $0.key < $1.key }
        plan.shadow = survivors.sorted()
        return plan
    }

    /// A one-way push: everything on the MealPlan list goes to Bring!, and
    /// nothing on the Bring! list is touched. What the "Send to Bring!" action
    /// does, for people who want the two lists kept apart.
    static func push(local: [BringSyncItem], remote: [BringSyncItem] = []) -> BringSyncPlan {
        let remotes = byKey(remote)
        var plan = BringSyncPlan()
        for (key, item) in byKey(local) {
            if counterpart(of: key, in: remotes)?.specification != item.specification {
                plan.addToBring.append(item)
            }
            plan.shadow.append(key)
        }
        plan.addToBring.sort { $0.key < $1.key }
        plan.shadow = Array(Set(plan.shadow).union(remotes.keys)).sorted()
        return plan
    }

    /// The changes this plan sends to Bring!.
    var bringChanges: [BringChange] {
        addToBring.map {
            BringChange(itemId: $0.name, spec: $0.specification, operation: .purchase)
        }
        + removeFromBring.map {
            BringChange(itemId: $0.name, spec: $0.specification, operation: .remove)
        }
    }

    /// The other list's line for this one. Exact first, then the same near
    /// matching the shopping list uses, so "Joghurt" here and "Jogurt" in
    /// Bring! don't spend every sync adding each other back.
    private static func counterpart(
        of key: String,
        in items: [String: BringSyncItem]
    ) -> BringSyncItem? {
        if let exact = items[key] { return exact }
        return items.first { IngredientMatching.keysMatch($0.key, key) }?.value
    }

    /// Whether the last sync knew this line, however it was spelled then.
    private static func knows(_ key: String, _ shadow: [String]) -> Bool {
        shadow.contains(key) || shadow.contains { IngredientMatching.keysMatch($0, key) }
    }

    /// First spelling wins, so a list that somehow holds the same thing twice
    /// doesn't push it twice.
    private static func byKey(_ items: [BringSyncItem]) -> [String: BringSyncItem] {
        var result: [String: BringSyncItem] = [:]
        for item in items where result[item.key] == nil {
            result[item.key] = item
        }
        return result
    }
}
