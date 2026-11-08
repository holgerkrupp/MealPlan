import Foundation

/// Two dishes in the library that are probably the same recipe stored twice.
///
/// Import already refuses most duplicates (`RecipeDuplicateDetector`), but a
/// library still collects them: two household members saving the same link,
/// an import from before the check existed, a sync that recreated a dish. This
/// only *finds* them; every resolution is the cook's explicit choice.
struct DuplicateCandidate: Identifiable, Hashable {
    /// Strongest signal first.
    enum Reason: Int, Comparable {
        /// Same source app and the source app's own recipe ID.
        case sameSourceRecord
        /// Same recipe web page, ignoring query and fragment.
        case sameSourceLink
        /// Same name and nearly the same ingredients.
        case sameNameAndIngredients

        static func < (lhs: Reason, rhs: Reason) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    var first: UUID
    var second: UUID
    var reason: Reason

    var id: String { DuplicatePairKey.make(first, second) }
}

/// The order-independent identifier of a pair, used to remember "keep both".
enum DuplicatePairKey {
    static func make(_ a: UUID, _ b: UUID) -> String {
        let ids = [a.uuidString, b.uuidString].sorted()
        return "\(ids[0])|\(ids[1])"
    }

    /// Dismissed pairs are a per-device convenience, not household data: a
    /// pair someone else chose to keep is still worth a look on this device.
    static let storageKey = "DuplicateReview.dismissedPairs"

    static func decode(_ raw: String) -> Set<String> {
        Set(raw.split(separator: "\n").map(String.init))
    }

    static func encode(_ keys: Set<String>) -> String {
        keys.sorted().joined(separator: "\n")
    }
}

enum LibraryDuplicateScanner {

    /// Every pair of dishes that look like one recipe stored twice. Dishes the
    /// cook already grouped as variants of each other are never reported, and
    /// neither are pairs in `dismissed` (see `DuplicatePairKey`).
    ///
    /// Bucketed by each signal so the work stays proportional to the pairs
    /// that can actually match rather than the square of the library.
    @MainActor
    static func candidates(in dishes: [Dish], dismissed: Set<String> = []) -> [DuplicateCandidate] {
        var found: [String: DuplicateCandidate] = [:]
        var bySource: [String: [Dish]] = [:]
        var byURL: [String: [Dish]] = [:]
        var byName: [String: [Dish]] = [:]

        for dish in dishes {
            if let sourceID = dish.importedSourceID?.trimmingCharacters(in: .whitespacesAndNewlines), !sourceID.isEmpty {
                let app = dish.importedSourceApp?.lowercased() ?? ""
                bySource["\(app)|\(sourceID)", default: []].append(dish)
            }
            if let url = RecipeDuplicateDetector.urlKey(dish.sourceURL) {
                byURL[url, default: []].append(dish)
            }
            let name = RecipeDuplicateDetector.normalizedName(dish.name)
            if !name.isEmpty {
                byName[name, default: []].append(dish)
            }
        }

        func consider(_ a: Dish, _ b: Dish, _ reason: DuplicateCandidate.Reason) {
            guard a !== b, a.uuid != b.uuid else { return }
            if let group = a.variantGroupID, group == b.variantGroupID { return }
            let key = DuplicatePairKey.make(a.uuid, b.uuid)
            guard !dismissed.contains(key) else { return }
            if let existing = found[key], existing.reason <= reason { return }
            // The older dish leads, so the one most likely to carry the
            // household's history is shown first.
            let (first, second) = a.dateCreated <= b.dateCreated ? (a, b) : (b, a)
            found[key] = DuplicateCandidate(first: first.uuid, second: second.uuid, reason: reason)
        }

        func pairs(_ bucket: [Dish], _ body: (Dish, Dish) -> Void) {
            guard bucket.count > 1 else { return }
            for i in bucket.indices {
                for j in bucket.index(after: i)..<bucket.endIndex {
                    body(bucket[i], bucket[j])
                }
            }
        }

        for bucket in bySource.values { pairs(bucket) { consider($0, $1, .sameSourceRecord) } }
        for bucket in byURL.values { pairs(bucket) { consider($0, $1, .sameSourceLink) } }

        var signatures: [ObjectIdentifier: Set<String>] = [:]
        func signature(_ dish: Dish) -> Set<String> {
            if let cached = signatures[ObjectIdentifier(dish)] { return cached }
            let value = RecipeDuplicateDetector.signature(of: dish)
            signatures[ObjectIdentifier(dish)] = value
            return value
        }
        for bucket in byName.values {
            pairs(bucket) { a, b in
                // Same name, different ingredients is another take on the dish
                // — a variant, not a duplicate — and stays out of this list.
                guard RecipeDuplicateDetector.ingredientsOverlap(signature(a), signature(b)) else { return }
                consider(a, b, .sameNameAndIngredients)
            }
        }

        let names = Dictionary(dishes.map { ($0.uuid, $0.name) }, uniquingKeysWith: { first, _ in first })
        return found.values.sorted { lhs, rhs in
            if lhs.reason != rhs.reason { return lhs.reason < rhs.reason }
            let left = names[lhs.first] ?? "", right = names[rhs.first] ?? ""
            if left != right { return left.localizedStandardCompare(right) == .orderedAscending }
            return lhs.id < rhs.id
        }
    }
}

/// Folding one dish of a duplicate pair into the other before it is deleted,
/// so deleting the copy never takes plans, history or unique content with it.
enum DuplicateDishMerge {

    /// What deleting `removed` in favour of `kept` would carry over, and what
    /// only `removed` has that would be lost with it.
    struct Preview: Equatable {
        var plannedMeals = 0
        var cookedLogs = 0
        var templateEntries = 0
        var routines = 0
        /// Photos `kept` doesn't have.
        var uniqueImages = 0
        /// Ingredients `kept` doesn't list.
        var uniqueIngredients = 0
        /// A method or notes text that differs from `kept`'s.
        var hasDifferentRecipeText = false

        var movesAnything: Bool { plannedMeals + cookedLogs + templateEntries + routines > 0 }
        var losesContent: Bool { uniqueImages > 0 || uniqueIngredients > 0 || hasDifferentRecipeText }
    }

    @MainActor
    static func preview(removing removed: Dish, keeping kept: Dish) -> Preview {
        let keptImages = Set((kept.images ?? []).compactMap(\.data))
        let removedText = removed.recipeText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let keptText = kept.recipeText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return Preview(
            plannedMeals: removed.entries?.count ?? 0,
            cookedLogs: removed.cookedLogs?.count ?? 0,
            templateEntries: removed.templateEntries?.count ?? 0,
            routines: removed.routines?.count ?? 0,
            uniqueImages: (removed.images ?? []).filter { image in
                guard let data = image.data else { return false }
                return !keptImages.contains(data)
            }.count,
            uniqueIngredients: RecipeDuplicateDetector.signature(of: removed)
                .subtracting(RecipeDuplicateDetector.signature(of: kept)).count,
            hasDifferentRecipeText: !removedText.isEmpty && removedText != keptText
        )
    }

    /// Re-points everything that refers to `removed` at `kept`: planned meals,
    /// cooked history, week-template slots and routines (which would otherwise
    /// cascade away with the dish). Also carries over what the household has
    /// learned about the recipe — usage, favourite, rating, tags — and source
    /// details `kept` lacks. The caller saves, checks `stillReferenced`, and
    /// only then deletes `removed`.
    @MainActor
    static func moveReferences(from removed: Dish, to kept: Dish) {
        guard removed !== kept else { return }
        for entry in removed.entries ?? [] { entry.dish = kept }
        for log in removed.cookedLogs ?? [] { log.dish = kept }
        for slot in removed.templateEntries ?? [] { slot.dish = kept }
        for routine in removed.routines ?? [] { routine.dish = kept }

        kept.usageCount += removed.usageCount
        if let used = removed.lastUsedDate, used > (kept.lastUsedDate ?? .distantPast) {
            kept.lastUsedDate = used
        }
        if removed.isFavorite { kept.isFavorite = true }
        if kept.rating == 0 { kept.rating = removed.rating }
        for tag in removed.tagNames { kept.addTag(tag) }

        if kept.sourceURLString?.isEmpty ?? true { kept.sourceURLString = removed.sourceURLString }
        if kept.deepLinkURLString?.isEmpty ?? true { kept.deepLinkURLString = removed.deepLinkURLString }
        if kept.importedSourceID?.isEmpty ?? true, let sourceID = removed.importedSourceID, !sourceID.isEmpty {
            kept.importedSourceID = sourceID
            kept.importedSourceApp = removed.importedSourceApp
        }
        kept.modifiedAt = .now
    }

    /// True while anything still points at `removed`. Deleting it then would
    /// orphan plans or — for routines, which cascade — delete them.
    @MainActor
    static func stillReferenced(_ removed: Dish) -> Bool {
        !(removed.entries ?? []).isEmpty
            || !(removed.cookedLogs ?? []).isEmpty
            || !(removed.templateEntries ?? []).isEmpty
            || !(removed.routines ?? []).isEmpty
    }
}
