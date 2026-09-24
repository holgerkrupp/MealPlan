import SwiftUI
import SwiftData

@MainActor
struct IngredientCleanupView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var context
    @Query(sort: \Ingredient.name) private var ingredients: [Ingredient]

    @State private var selectedSuggestion: IngredientCleanupSuggestion?
    @State private var showingBatchConfirmation = false
    @State private var showingBatchError = false
    @State private var batchErrorMessage = ""

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
        List {
            if suggestions.isEmpty {
                ContentUnavailableView(
                    String(localized: "No possible duplicates"),
                    systemImage: "checkmark.circle",
                    description: Text("New uncertain matches will appear here after an import or recipe edit.")
                )
            } else {
                Section {
                    ForEach(suggestions) { suggestion in
                        Button { selectedSuggestion = suggestion } label: {
                            suggestionRow(suggestion)
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint(String(localized: "Opens ingredient cleanup details"))
                    }
                } header: {
                    Text(String(localized: "Possible duplicates"))
                } footer: {
                    Text("Review the evidence before changing your catalogue. Keeping items separate is remembered for this spelling pair.")
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
                        Label(String(localized: "Merge high-confidence"), systemImage: "checkmark.seal")
                    }
                    .accessibilityHint(String(localized: "Merges only high-confidence suggestions without metadata conflicts"))
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
            Text("Only suggestions with high matcher confidence and matching category, aisle, pantry, and nutrition data will be merged. You can undo the last merge from the Edit menu.")
        }
        .alert(String(localized: "Couldn’t finish cleanup"), isPresented: $showingBatchError) {
            Button(String(localized: "OK"), role: .cancel) {}
        } message: {
            Text(batchErrorMessage)
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
                Button {
                    if suggestion.hasMetadataConflict {
                        showingConflictConfirmation = true
                    } else {
                        showingMergeConfirmation = true
                    }
                } label: {
                    Label(String(localized: "Merge / Same ingredient"), systemImage: "arrow.triangle.merge")
                }
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
            Button(String(localized: "Merge and keep canonical details")) { merge() }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text("The canonical ingredient’s category, aisle, pantry setting, and nutrition values will be kept. Review the differences above before continuing.")
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
        }
    }

    private func merge() {
        do {
            try IngredientCleanupService.merge(suggestion, canonicalName: canonicalName, context: context)
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
}
