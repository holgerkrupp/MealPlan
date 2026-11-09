import SwiftUI
import SwiftData

/// Library-wide review of recipes that look stored twice.
///
/// Nothing here happens on its own: each pair is inspected side by side and
/// resolved by an explicit choice — keep both (remembered on this device),
/// group them as variants, or delete one after moving its plans and history
/// onto the other.
@MainActor
struct DuplicateReviewView: View {
    @Environment(AppState.self) private var appState
    @Query private var dishes: [Dish]
    @AppStorage(DuplicatePairKey.storageKey) private var dismissedRaw = ""

    init(householdID: UUID?) {
        // Same scoping as the library: never another household's recipes.
        let scopedHouseholdID = householdID ?? UUID()
        _dishes = Query(filter: #Predicate<Dish> { $0.household?.uuid == scopedHouseholdID })
    }

    var body: some View {
        let candidates = LibraryDuplicateScanner.candidates(
            in: dishes, dismissed: DuplicatePairKey.decode(dismissedRaw)
        )
        let byID = Dictionary(dishes.map { ($0.uuid, $0) }, uniquingKeysWith: { first, _ in first })
        List {
            if candidates.isEmpty {
                ContentUnavailableView(
                    String(localized: "No duplicate recipes"),
                    systemImage: "checkmark.circle",
                    description: Text("Recipes that share a source or the same name and ingredients would appear here.")
                )
            } else {
                Section {
                    ForEach(candidates) { candidate in
                        if let first = byID[candidate.first], let second = byID[candidate.second] {
                            NavigationLink {
                                DuplicatePairView(first: first, second: second, reason: candidate.reason, allDishes: dishes)
                            } label: {
                                row(first, second, reason: candidate.reason)
                            }
                        }
                    }
                } footer: {
                    Text("Nothing is merged or deleted until you choose. Keeping both is remembered on this device.")
                }
            }
        }
        .navigationTitle(String(localized: "Duplicate Recipes"))
    }

    private func row(_ first: Dish, _ second: Dish, reason: DuplicateCandidate.Reason) -> some View {
        HStack(spacing: 12) {
            DishThumbnail(dish: first, size: 44, cornerRadius: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(first.name)
                if first.name != second.name {
                    Text(second.name).foregroundStyle(.secondary)
                }
                Text(reason.localizedDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

extension DuplicateCandidate.Reason {
    var localizedDescription: String {
        switch self {
        case .sameSourceRecord: String(localized: "Imported from the same source recipe")
        case .sameSourceLink: String(localized: "Saved from the same web page")
        case .sameNameAndIngredients: String(localized: "Same name and ingredients")
        }
    }
}

/// One candidate pair, side by side, with the explicit resolutions.
@MainActor
struct DuplicatePairView: View {
    let first: Dish
    let second: Dish
    let reason: DuplicateCandidate.Reason
    let allDishes: [Dish]

    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @AppStorage(DuplicatePairKey.storageKey) private var dismissedRaw = ""

    /// The dish the cook asked to delete; drives the confirmation.
    @State private var pendingRemoval: Dish?
    @State private var errorMessage: String?

    private var canEdit: Bool {
        !appState.isGuest && HouseholdMutationAuthorization.canMutate(household: appState.currentHousehold)
    }

    /// Once one side is deleted the screen is on its way out; reading the
    /// deleted model's properties during that pop would trap.
    private var isResolved: Bool {
        first.isDeleted || second.isDeleted || first.modelContext == nil || second.modelContext == nil
    }

    var body: some View {
        ScrollView {
            if !isResolved {
                VStack(alignment: .leading, spacing: 20) {
                    Text(reason.localizedDescription)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    HStack(alignment: .top, spacing: 12) {
                        DuplicateDishColumn(dish: first)
                        Divider()
                        DuplicateDishColumn(dish: second)
                    }

                    if canEdit {
                        actions
                    }
                }
                .padding()
                .frame(maxWidth: 900, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle(isResolved ? "" : first.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .confirmationDialog(
            pendingRemoval.map { String(localized: "Delete “\($0.name)”?") } ?? "",
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            titleVisibility: .visible,
            presenting: pendingRemoval
        ) { removed in
            Button(String(localized: "Delete Recipe"), role: .destructive) {
                delete(removed, keeping: removed === first ? second : first)
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: { removed in
            Text(confirmationMessage(removing: removed, keeping: removed === first ? second : first))
        }
        .alert(
            String(localized: "Couldn’t delete recipe"),
            isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
        ) {
            Button(String(localized: "OK"), role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(String(localized: "Keep Both"), systemImage: "checkmark") {
                keepBoth()
            }
            Button(String(localized: "Group as Variants"), systemImage: "square.stack") {
                groupAsVariants()
            }
            Button(String(localized: "Delete “\(first.name)” (left)"), systemImage: "trash", role: .destructive) {
                pendingRemoval = first
            }
            Button(String(localized: "Delete “\(second.name)” (right)"), systemImage: "trash", role: .destructive) {
                pendingRemoval = second
            }
            Text("Deleting keeps unique photos, ingredient lines, method notes and recipe details, and moves planned meals, cooking history, template slots and routines to the recipe you keep.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.bordered)
    }

    // MARK: - Work

    private func keepBoth() {
        var keys = DuplicatePairKey.decode(dismissedRaw)
        keys.insert(DuplicatePairKey.make(first.uuid, second.uuid))
        dismissedRaw = DuplicatePairKey.encode(keys)
        dismiss()
    }

    private func groupAsVariants() {
        DishVariants.join(second, with: first, in: allDishes)
        do {
            try context.save()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func confirmationMessage(removing removed: Dish, keeping kept: Dish) -> String {
        let preview = DuplicateDishMerge.preview(removing: removed, keeping: kept)
        var lines: [String] = []
        if preview.movesAnything {
            lines.append(String(localized: "Moved to “\(kept.name)”: \(preview.plannedMeals) planned meals, \(preview.cookedLogs) cooked entries, \(preview.templateEntries) template slots, \(preview.routines) routines."))
        }
        if preview.uniqueImages > 0 {
            lines.append(String(localized: "\(preview.uniqueImages) unique photos will be kept with the recipe you choose to keep."))
        }
        if preview.uniqueIngredients > 0 {
            lines.append(String(localized: "\(preview.uniqueIngredients) unique ingredient lines, including their quantities and notes, will be kept."))
        }
        if preview.hasDifferentRecipeText {
            lines.append(String(localized: "Its method or notes will be added to the recipe you keep."))
        }
        if lines.isEmpty {
            lines.append(String(localized: "No unique recipe content needs to be added."))
        }
        return lines.joined(separator: "\n\n")
    }

    /// The same delete the recipe screen does — `context.delete` plus a save,
    /// which household sync turns into a deletion marker — preceded by moving
    /// every reference onto the kept dish and saving that first, so the
    /// cascade on routines can never take one with it.
    private func delete(_ removed: Dish, keeping kept: Dish) {
        pendingRemoval = nil
        DuplicateDishMerge.moveReferences(from: removed, to: kept)
        do {
            try context.save()
            guard !DuplicateDishMerge.stillReferenced(removed) else {
                errorMessage = String(localized: "Its plans couldn’t be moved, so nothing was deleted.")
                return
            }
            context.delete(removed)
            try context.save()
            SharedStore.reloadWidgets()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// One side of the comparison.
@MainActor
private struct DuplicateDishColumn: View {
    let dish: Dish

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            DishThumbnail(dish: dish, size: 96, cornerRadius: 14)
            Text(dish.name)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 2) {
                fact(String(localized: "Added"), dish.dateCreated.formatted(date: .abbreviated, time: .omitted))
                fact(String(localized: "Photos"), "\(dish.images?.count ?? 0)")
                fact(String(localized: "Planned"), "\(dish.entries?.count ?? 0)")
                fact(String(localized: "Cooked"), "\(dish.cookedLogs?.count ?? 0)")
                if let routines = dish.routines, !routines.isEmpty {
                    fact(String(localized: "Routines"), "\(routines.count)")
                }
                if let slots = dish.templateEntries, !slots.isEmpty {
                    fact(String(localized: "Template slots"), "\(slots.count)")
                }
                if let host = dish.sourceURL?.host() {
                    fact(String(localized: "Source"), host)
                }
            }
            .font(.caption)

            let ingredients = dish.sortedIngredients
            Text(String(localized: "Ingredients"))
                .font(.subheadline.bold())
            if ingredients.isEmpty {
                Text("None").font(.caption).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(ingredients, id: \.persistentModelID) { line in
                        Text(line.rawText ?? line.ingredient?.name ?? "")
                            .font(.caption)
                    }
                }
            }

            Text(String(localized: "Method"))
                .font(.subheadline.bold())
            if let text = dish.recipeText?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                Text(text)
                    .font(.caption)
                    .lineLimit(20)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("None").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func fact(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(label).foregroundStyle(.secondary)
            Text(value)
        }
    }
}
