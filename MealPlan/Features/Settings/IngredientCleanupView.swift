import SwiftUI
import SwiftData

@MainActor
struct IngredientCleanupView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let householdID = appState.currentHousehold?.uuid
        IngredientCleanupContent(householdID: householdID)
            .id(householdID)
    }
}

@MainActor
private struct IngredientCleanupContent: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var context
    @Query private var ingredients: [Ingredient]

    @State private var selectedSuggestion: IngredientCleanupSuggestion?
    @State private var showingBatchConfirmation = false
    @State private var showingBatchError = false
    @State private var batchErrorMessage = ""
    @State private var integrityAudit: IngredientIntegrityAudit?

    init(householdID: UUID?) {
        let scopedHouseholdID = householdID ?? UUID()
        _ingredients = Query(FetchDescriptor<Ingredient>(
            predicate: #Predicate { $0.household?.uuid == scopedHouseholdID },
            sortBy: [SortDescriptor(\Ingredient.name)]
        ))
    }

    private var suggestions: [IngredientCleanupSuggestion] {
        // Reading the query keeps this view invalidated after a merge or a
        // rejection, while the active household remains the source of truth.
        _ = ingredients.count
        return IngredientCleanupService.suggestions(in: appState.currentHousehold)
    }

    private var batchSuggestions: [IngredientCleanupSuggestion] {
        IngredientCleanupService.highConfidenceNonConflicting(in: appState.currentHousehold)
    }

    var body: some View {
        let suggestions = suggestions
        let batchSuggestions = suggestions.filter(\.isHighConfidenceAndNonConflicting)
        List {
            integritySection

            if suggestions.isEmpty {
                ContentUnavailableView(
                    String(localized: "No possible duplicates"),
                    systemImage: "checkmark.circle",
                    description: Text("New uncertain matches will appear here after an import or recipe edit.")
                )
            } else {
                ForEach(Dictionary(grouping: suggestions, by: { IngredientMatching.key(for: $0.duplicate.name) }).keys.sorted(), id: \.self) { nameKey in
                    Section {
                        ForEach(Dictionary(grouping: suggestions, by: { IngredientMatching.key(for: $0.duplicate.name) })[nameKey] ?? []) { suggestion in
                            Button { selectedSuggestion = suggestion } label: {
                                suggestionRow(suggestion)
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint(String(localized: "Opens ingredient cleanup details"))
                        }
                    } header: {
                        Text(nameKey.capitalized)
                    }
                }
            }
        }
        .navigationTitle(String(localized: "Ingredient Cleanup"))
        .toolbar {
            if !batchSuggestions.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingBatchConfirmation = true
                    } label: {
                        Label(String(localized: "Merge clear matches"), systemImage: "checkmark.seal")
                    }
                    .accessibilityHint(String(localized: "Merges exact and high-confidence suggestions without metadata conflicts"))
                }
            }
        }
        .sheet(item: $selectedSuggestion) { suggestion in
            NavigationStack {
                IngredientCleanupDetailView(suggestion: suggestion)
            }
            .dismissesOnOutsideClick()
        }
        .confirmationDialog(
            String(localized: "Merge high-confidence suggestions?"),
            isPresented: $showingBatchConfirmation,
            titleVisibility: .visible
        ) {
            Button(String(localized: "Merge (batchSuggestions.count)")) { mergeBatch() }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text("Only exact or high-confidence suggestions with matching category, aisle, pantry, nutrition, and stock data will be merged. You can undo the last merge from the Edit menu.")
        }
        .alert(String(localized: "Couldn’t finish cleanup"), isPresented: $showingBatchError) {
            Button(String(localized: "OK"), role: .cancel) {}
        } message: {
            Text(batchErrorMessage)
        }
    }

    @ViewBuilder
    private var integritySection: some View {
        Section {
            Button {
                guard let household = appState.currentHousehold else { return }
                integrityAudit = IngredientIntegrityAuditor.audit(household: household, context: context)
            } label: {
                Label(String(localized: "Check ingredient data"), systemImage: "checkmark.shield")
            }

            if let household = appState.currentHousehold,
               household.ingredientMergeAuditTrail.contains(where: { $0.revertedAt == nil }) {
                Button(String(localized: "Reverse last ingredient merge")) {
                    reverseLatestMerge(in: household)
                }
            }

            if let integrityAudit {
                if integrityAudit.issues.isEmpty {
                    Label(String(localized: "No integrity issues found"), systemImage: "checkmark.circle")
                        .foregroundStyle(.green)
                } else {
                    Text(String(localized: "\(integrityAudit.issues.count) issues found"))
                        .foregroundStyle(.secondary)
                    let safeIssues = integrityAudit.issues.filter(\.isSafeToRepair)
                    if !safeIssues.isEmpty {
                        Button(String(localized: "Repair \(safeIssues.count) safe issues")) {
                            repair(integrityAudit)
                        }
                    }
                    if integrityAudit.issues.contains(where: { !$0.isSafeToRepair }) {
                        Text("Potential duplicates and broken links are reported for review; this repair never merges or deletes data.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text(String(localized: "Data integrity"))
        } footer: {
            Text("Checks existing recipe and shopping-list links plus catalogue search keys. Automatic repair is limited to rebuilding stale search keys.")
        }
    }

    private func suggestionRow(_ suggestion: IngredientCleanupSuggestion) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(suggestion.duplicate.name)
                        .font(.headline)
                    Label(String(localized: "Possible match: \(suggestion.canonical.name)"), systemImage: "arrow.right")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(percentage(suggestion.confidence))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(suggestion.isHighConfidenceAndNonConflicting ? .green : .orange)
            }
            Text(reasonText(for: suggestion))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private func percentage(_ value: Double) -> String {
        String(localized: "(Int((value * 100).rounded()))% match")
    }

    private func repair(_ audit: IngredientIntegrityAudit) {
        guard let household = appState.currentHousehold else { return }
        do {
            _ = try IngredientIntegrityRepairService.repairSafely(audit, in: household, context: context)
            integrityAudit = IngredientIntegrityAuditor.audit(household: household, context: context)
        } catch {
            batchErrorMessage = String(localized: "The safe repairs could not be saved.")
            showingBatchError = true
        }
    }

    private func reverseLatestMerge(in household: Household) {
        do {
            _ = try IngredientMergeService.reverseLatestMerge(in: household, context: context)
            integrityAudit = IngredientIntegrityAuditor.audit(household: household, context: context)
        } catch {
            batchErrorMessage = String(localized: "The last ingredient merge could not be reversed.")
            showingBatchError = true
        }
    }

    private func reasonText(for suggestion: IngredientCleanupSuggestion) -> String {
        suggestion.match.reasons.map(reasonName).joined(separator: ", ")
    }

    private func reasonName(_ reason: IngredientMatchReason) -> String {
        switch reason {
        case .exactName: String(localized: "same name")
        case .exactAlias: String(localized: "known alias")
        case .normalizedKey: String(localized: "same normalized words")
        case .inflection: String(localized: "singular/plural form")
        case .spellingDistance: String(localized: "close spelling")
        case .tokenOverlap: String(localized: "same words in a different order")
        case .candidateCollision: String(localized: "more than one possible match")
        case .knownVocabulary: String(localized: "same known ingredient in another language")
        }
    }

    private func mergeBatch() {
        let candidates = batchSuggestions
        do {
            for suggestion in candidates {
                try IngredientCleanupService.merge(suggestion, context: context)
            }
            try context.save()
            let undo = context.undoManager
            appState.offerUndo(String(localized: "Ingredients merged")) {
                undo?.undo()
                try? context.save()
            }
        } catch {
            batchErrorMessage = error.localizedDescription
            showingBatchError = true
        }
    }
}

@MainActor
private struct IngredientCleanupDetailView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    let suggestion: IngredientCleanupSuggestion
    @State private var canonicalName: String
    @State private var stockChoices = IngredientStockMergeChoices()
    @State private var showingMergeConfirmation = false
    @State private var showingConflictConfirmation = false

    init(suggestion: IngredientCleanupSuggestion) {
        self.suggestion = suggestion
        _canonicalName = State(initialValue: suggestion.canonical.name)
    }

    var body: some View {
        Form {
            Section {
                LabeledContent(String(localized: "Alternate spelling"), value: suggestion.duplicate.name)
                TextField(String(localized: "Canonical display name"), text: $canonicalName)
            } header: {
                Text(String(localized: "Choose the catalogue name"))
            }

            Section {
                evidenceRow(String(localized: "Why it may match"), suggestion.match.reasons.map(reasonName).joined(separator: ", "))
                evidenceRow(String(localized: "Confidence"), "\(Int((suggestion.confidence * 100).rounded()))%")
            } header: {
                Text(String(localized: "Matcher evidence"))
            }

            Section(String(localized: "Recipes using \(suggestion.canonical.name)")) {
                recipeExamples(suggestion.canonicalDishes)
            }

            Section(String(localized: "Recipes using \(suggestion.duplicate.name)")) {
                recipeExamples(suggestion.duplicateDishes)
            }

            Section(String(localized: "Catalogue differences")) {
                differenceRow(String(localized: "Category"), suggestion.canonical.category.localizedName, suggestion.duplicate.category.localizedName, differs: suggestion.categoryDiffers)
                differenceRow(String(localized: "Aisle"), suggestion.canonical.aisleName, suggestion.duplicate.aisleName, differs: suggestion.aisleDiffers)
                differenceRow(String(localized: "Pantry staple"), yesNo(suggestion.canonical.isPantryStaple), yesNo(suggestion.duplicate.isPantryStaple), differs: suggestion.pantryStatusDiffers)
                differenceRow(String(localized: "Nutrition"), nutritionText(suggestion.canonical), nutritionText(suggestion.duplicate), differs: suggestion.nutritionDiffers)
            }

            Section {
                stockValueRow(IngredientStockConflictField.status, canonical: suggestion.canonical.inventoryMode.localizedName, duplicate: suggestion.duplicate.inventoryMode.localizedName)
                stockValueRow(IngredientStockConflictField.amount,
                              canonical: PantryRowLabel.amountText(for: suggestion.canonical, system: appState.unitSystem) ?? String(localized: "Not set"),
                              duplicate: PantryRowLabel.amountText(for: suggestion.duplicate, system: appState.unitSystem) ?? String(localized: "Not set"))
                stockValueRow(IngredientStockConflictField.bestBefore,
                              canonical: dateText(suggestion.canonical.inventoryBestBefore),
                              duplicate: dateText(suggestion.duplicate.inventoryBestBefore))
                stockValueRow(IngredientStockConflictField.location,
                              canonical: locationText(suggestion.canonical),
                              duplicate: locationText(suggestion.duplicate))
                stockValueRow(IngredientStockConflictField.note,
                              canonical: suggestion.canonical.trimmedInventoryNote ?? String(localized: "Not set"),
                              duplicate: suggestion.duplicate.trimmedInventoryNote ?? String(localized: "Not set"))

                if !suggestion.stockConflicts.isEmpty {
                    Text("Choose which row’s value to keep for each difference. Amounts are never added together; choose Keep separate to preserve both records.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    ForEach(suggestion.stockConflicts) { field in
                        Picker(field.localizedName, selection: stockChoiceBinding(for: field)) {
                            Text("Choose value").tag(nil as IngredientStockSource?)
                            Text(suggestion.canonical.name).tag(IngredientStockSource?.some(.canonical))
                            Text(suggestion.duplicate.name).tag(IngredientStockSource?.some(.duplicate))
                        }
                    }
                }
            } header: {
                Text(String(localized: "Pantry stock"))
            } footer: {
                Text("Values present on only one row are retained automatically.")
            }

            Section {
                Button {
                    if suggestion.hasMetadataConflict {
                        showingConflictConfirmation = true
                    } else {
                        showingMergeConfirmation = true
                    }
                } label: {
                    Label(String(localized: "Merge / Same ingredient"), systemImage: "arrow.triangle.merge")
                }
                .disabled(!stockChoices.resolves(suggestion.stockConflicts))
                .accessibilityHint(String(localized: "Moves recipe and shopping list relationships to the canonical ingredient"))

                Button {
                    IngredientCleanupService.keepSeparate(suggestion)
                    try? context.save()
                    dismiss()
                } label: {
                    Label(String(localized: "Keep separate"), systemImage: "xmark.circle")
                }
                .accessibilityHint(String(localized: "Remembers that these spellings are different"))
            } footer: {
                Text("Merging keeps the recipe wording and moves recipe and shopping list relationships to the canonical ingredient. The last merge can be undone from the Edit menu.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle(String(localized: "Review ingredient"))
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(String(localized: "Done")) { dismiss() }
            }
        }
        .confirmationDialog(String(localized: "Merge ingredients?"), isPresented: $showingMergeConfirmation, titleVisibility: .visible) {
            Button(String(localized: "Merge")) { merge() }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text("Recipes and shopping list items using “\(suggestion.duplicate.name)” will use “\(canonicalName)” from now on. The alternate spelling is saved as an alias.")
        }
        .confirmationDialog(String(localized: "Merge despite catalogue differences?"), isPresented: $showingConflictConfirmation, titleVisibility: .visible) {
            Button(String(localized: "Merge with reviewed values")) { merge() }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text("The canonical ingredient’s category, aisle, pantry setting, and nutrition values will be kept. Stock conflicts use the values you selected above. Review the differences before continuing.")
        }
    }

    private func evidenceRow(_ title: String, _ value: String) -> some View {
        LabeledContent(title) { Text(value).foregroundStyle(.secondary) }
    }

    @ViewBuilder
    private func recipeExamples(_ dishes: [Dish]) -> some View {
        if dishes.isEmpty {
            Text(String(localized: "No recipes")).foregroundStyle(.secondary)
        } else {
            ForEach(dishes.prefix(5)) { dish in
                Label(dish.name, systemImage: "fork.knife")
            }
        }
    }

    private func differenceRow(_ title: String, _ canonical: String, _ duplicate: String, differs: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.subheadline.weight(.medium))
            HStack {
                Text(suggestion.canonical.name).foregroundStyle(.secondary)
                Text(canonical)
                Spacer()
                Text(duplicate)
                Text(suggestion.duplicate.name).foregroundStyle(.secondary)
            }
            .font(.caption)
            if differs {
                Label(String(localized: "Different"), systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
    }

    private func yesNo(_ value: Bool) -> String { value ? String(localized: "Yes") : String(localized: "No") }

    private func nutritionText(_ ingredient: Ingredient) -> String {
        guard let facts = ingredient.nutritionFacts else { return String(localized: "Not set") }
        return "\(facts.energyKcal.formatted(.number.precision(.fractionLength(0...1)))) kcal / \(ingredient.nutritionReference.localizedName)"
    }

    private func reasonName(_ reason: IngredientMatchReason) -> String {
        switch reason {
        case .exactName: String(localized: "same name")
        case .exactAlias: String(localized: "known alias")
        case .normalizedKey: String(localized: "same normalized words")
        case .inflection: String(localized: "singular/plural form")
        case .spellingDistance: String(localized: "close spelling")
        case .tokenOverlap: String(localized: "same words in a different order")
        case .candidateCollision: String(localized: "more than one possible match")
        case .knownVocabulary: String(localized: "same known ingredient in another language")
        }
    }

    private func merge() {
        do {
            try IngredientCleanupService.merge(suggestion, canonicalName: canonicalName, stockChoices: stockChoices, context: context)
            try context.save()
            let undo = context.undoManager
            appState.offerUndo(String(localized: "Ingredient merged")) {
                undo?.undo()
                try? context.save()
            }
            dismiss()
        } catch {
            // A failed save leaves both catalogue rows intact. The dialog is
            // intentionally left open so the user can try again or cancel.
        }
    }

    private func stockChoiceBinding(for field: IngredientStockConflictField) -> Binding<IngredientStockSource?> {
        Binding(get: { stockChoices[field] }, set: { stockChoices[field] = $0 })
    }

    private func stockValueRow(_ field: IngredientStockConflictField, canonical: String, duplicate: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(field.localizedName).font(.subheadline.weight(.medium))
            HStack {
                Text(suggestion.canonical.name).foregroundStyle(.secondary)
                Text(canonical)
                Spacer(minLength: 8)
                Text(duplicate)
                Text(suggestion.duplicate.name).foregroundStyle(.secondary)
            }
            .font(.caption)
        }
    }

    private func dateText(_ date: Date?) -> String {
        date?.formatted(date: .abbreviated, time: .omitted) ?? String(localized: "Not set")
    }

    private func locationText(_ ingredient: Ingredient) -> String {
        if let custom = ingredient.trimmedCustomStorageLocation, !custom.isEmpty { return custom }
        return ingredient.storageLocation?.localizedName ?? String(localized: "Not set")
    }
}
