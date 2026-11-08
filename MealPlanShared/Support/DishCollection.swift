import Foundation

/// Named recipe collections ("Weeknight", "Christmas baking", "Grandma's
/// cookbook"), stored as plain names in `Dish.collectionNames`.
///
/// Like tags, a collection has no record of its own: it exists while at least
/// one dish carries its name, so there is nothing extra to sync, back up or
/// garbage-collect, and the field already travels through the household
/// codec, backups and recipe archives. Names are compared through `DishTag`'s
/// normalization, so "Weeknight" and "weeknight " are one collection. A dish
/// may belong to any number of collections.
///
/// Renaming or deleting a collection rewrites the name on every dish that
/// carries it; the dishes themselves are never touched otherwise.
enum DishCollection {

    /// Every collection in use across the given name lists with its dish
    /// count, alphabetically. Takes plain arrays so a background actor can
    /// build it without sending models across.
    static func usage(fromCollectionLists lists: [[String]]) -> [(name: String, count: Int)] {
        DishTag.usage(fromTagLists: lists)
            .map { (name: $0.tag, count: $0.count) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The collection names a dish list should carry after `name` was renamed
    /// to `newName`. Unchanged when the list doesn't contain `name`.
    static func renaming(_ name: String, to newName: String, in names: [String]) -> [String] {
        let cleaned = DishTag.clean(newName)
        guard !cleaned.isEmpty, DishTag.contains(names, name) else { return names }
        return DishTag.merge(DishTag.removing(name, from: names), adding: [cleaned])
    }

    /// Renames a collection on every dish carrying it. Renaming onto an
    /// existing collection merges the two. Returns the dishes that changed.
    @MainActor
    @discardableResult
    static func rename(_ name: String, to newName: String, in dishes: [Dish], now: Date = .now) -> [Dish] {
        var changed: [Dish] = []
        for dish in dishes {
            let updated = renaming(name, to: newName, in: dish.collectionNames)
            guard updated != dish.collectionNames else { continue }
            dish.collectionNames = updated
            dish.modifiedAt = now
            changed.append(dish)
        }
        return changed
    }

    /// Removes a collection from every dish. The dishes stay in the library.
    @MainActor
    @discardableResult
    static func delete(_ name: String, from dishes: [Dish], now: Date = .now) -> [Dish] {
        var changed: [Dish] = []
        for dish in dishes where dish.isInCollection(name) {
            dish.removeFromCollection(name)
            dish.modifiedAt = now
            changed.append(dish)
        }
        return changed
    }
}

/// One bulk change to the labels of several dishes at once — the library's
/// multi-select "Add to collection" / "Remove tag" actions.
enum DishLabelEdit: Equatable, Sendable {
    case addTag(String)
    case removeTag(String)
    case addToCollection(String)
    case removeFromCollection(String)

    /// What a set of dishes looked like before an edit, so the edit can be
    /// undone without touching anything else on the dishes.
    struct Snapshot: Sendable {
        struct Labels: Equatable, Sendable {
            var tagNames: [String]
            var collectionNames: [String]
        }
        var labels: [UUID: Labels]
    }

    /// Applies the edit to every dish and returns the state to restore for an
    /// undo. Dishes the edit doesn't change are left alone (and not stamped
    /// as modified, so they don't sync for nothing).
    @MainActor
    func apply(to dishes: [Dish], now: Date = .now) -> Snapshot {
        var snapshot = Snapshot(labels: [:])
        for dish in dishes {
            let before = Snapshot.Labels(tagNames: dish.tagNames, collectionNames: dish.collectionNames)
            switch self {
            case .addTag(let tag): dish.addTag(tag)
            case .removeTag(let tag): dish.removeTag(tag)
            case .addToCollection(let name): dish.addToCollection(name)
            case .removeFromCollection(let name): dish.removeFromCollection(name)
            }
            guard dish.tagNames != before.tagNames || dish.collectionNames != before.collectionNames else {
                continue
            }
            dish.modifiedAt = now
            snapshot.labels[dish.uuid] = before
        }
        return snapshot
    }

    /// Puts the dishes' tags and collections back the way the snapshot saw them.
    @MainActor
    static func restore(_ snapshot: Snapshot, on dishes: [Dish], now: Date = .now) {
        for dish in dishes {
            guard let labels = snapshot.labels[dish.uuid] else { continue }
            dish.tagNames = labels.tagNames
            dish.collectionNames = labels.collectionNames
            dish.modifiedAt = now
        }
    }
}

extension Dish {
    /// Collections in display order.
    var sortedCollectionNames: [String] { DishTag.sorted(collectionNames) }

    func isInCollection(_ name: String) -> Bool { DishTag.contains(collectionNames, name) }

    /// Adds the dish to a collection unless it is already in it under any spelling.
    func addToCollection(_ name: String) {
        let merged = DishTag.merge(collectionNames, adding: [name])
        if merged != collectionNames { collectionNames = merged }
    }

    func removeFromCollection(_ name: String) {
        let remaining = DishTag.removing(name, from: collectionNames)
        if remaining != collectionNames { collectionNames = remaining }
    }
}
