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
    @State private var pendingDeletion: IngredientCleanupSuggestion?
    @State private var pendingBatchSuggestions: [IngredientCleanupSuggestion]?
    @State private var showingBatchConfirmation = false
    @State private var showingDeleteConfirmation = false
    @State private var showingBatchError = false
    @State private var batchErrorMessage = ""
    @State private var integrityAudit: IngredientIntegrityAudit?
    @State private var selectedRecipeIssue: IngredientIntegrityIssue?
    @State private var isAuditingRecipeIngredients = false

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
        var seenDuplicateIDs = Set<UUID>()
        return IngredientCleanupService.highConfidenceNonConflicting(in: appState.currentHousehold)
            .filter { seenDuplicateIDs.insert($0.duplicate.uuid).inserted }
    }

    private var batchActionTitle: String {
        let count = (pendingBatchSuggestions ?? batchSuggestions).count
        return count == 1
            ? String(localized: "Merge 1 duplicate")
            : String(localized: "Merge \(count) duplicates")
    }

    private var canEditIngredients: Bool {
        appState.collaboration.canEdit
            && HouseholdMutationAuthorization.canMutate(household: appState.currentHousehold)
    }

    var body: some View {
        let suggestions = suggestions
        let batchSuggestions = self.batchSuggestions
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
                            .swipeActions(edge: .trailing) {
                                if canEditIngredients {
                                    Button(String(localized: "Delete"), systemImage: "trash", role: .destructive) {
                                        requestDelete(suggestion)
                                    }
                                }
                            }
                            .contextMenu {
                                if canEditIngredients {
                                    Button(String(localized: "Delete"), systemImage: "trash", role: .destructive) {
                                        requestDelete(suggestion)
                                    }
                                }
                            }
                        }
                    } header: {
                        Text(nameKey.capitalized)
                    }
                }
            }
        }
        .navigationTitle(String(localized: "Ingredient Cleanup"))
        .toolbar {
            if !batchSuggestions.isEmpty && canEditIngredients {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        pendingBatchSuggestions = batchSuggestions
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
        .sheet(item: $selectedRecipeIssue, onDismiss: refreshIntegrityAudit) { issue in
            NavigationStack {
                IngredientRecipeIssueDetailView(issue: issue)
            }
            .dismissesOnOutsideClick()
        }
        .confirmationDialog(
            String(localized: "Merge high-confidence suggestions?"),
            isPresented: $showingBatchConfirmation,
            titleVisibility: .visible
        ) {
            Button(batchActionTitle) { mergeBatch() }
            Button(String(localized: "Cancel"), role: .cancel) { pendingBatchSuggestions = nil }
        } message: {
            Text("Only exact or high-confidence suggestions with matching category, aisle, pantry, nutrition, and stock data will be merged. You can undo the last merge from the Edit menu.")
        }
        .alert(String(localized: "Couldn’t finish cleanup"), isPresented: $showingBatchError) {
            Button(String(localized: "OK"), role: .cancel) {}
        } message: {
            Text(batchErrorMessage)
        }
        .confirmationDialog(
            deleteConfirmationTitle,
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            if let pendingDeletion {
                Button(String(localized: "Review match")) {
                    selectedSuggestion = pendingDeletion
                    self.pendingDeletion = nil
                }
                Button(String(localized: "Delete and unlink uses"), role: .destructive) {
                    deleteUnlinked(pendingDeletion)
                }
            }
            Button(String(localized: "Cancel"), role: .cancel) { pendingDeletion = nil }
        } message: {
            if let pendingDeletion {
                Text(deleteImpact(for: pendingDeletion))
            }
        }
    }

    @ViewBuilder
    private var integritySection: some View {
        Section {
            if isAuditingRecipeIngredients {
                Label(String(localized: "Checking recipe ingredients…"), systemImage: "hourglass")
                    .foregroundStyle(.secondary)
            } else {
                Button {
                    startIntegrityAudit()
                } label: {
                    Label(String(localized: "Check recipe ingredients"), systemImage: "checkmark.shield")
                }
                .accessibilityHint(String(localized: "Scans recipe lines without changing them"))
            }

            if canEditIngredients,
               let household = appState.currentHousehold,
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

                    let recipeIssues = integrityAudit.recipeIngredientIssues
                    if !recipeIssues.isEmpty {
                        let affectedRecipeCount = Set(recipeIssues.compactMap(\.dishUUID)).count
                        Text(String(localized: "\(affectedRecipeCount) recipes contain \(recipeIssues.count) ingredient findings"))
                            .font(.subheadline.weight(.medium))
                        ForEach(Array(recipeIssues.prefix(100))) { issue in
                            Button {
                                selectedRecipeIssue = issue
                            } label: {
                                recipeIssueRow(issue)
                            }
                            .buttonStyle(.plain)
                        }
                        if recipeIssues.count > 100 {
                            Text(String(localized: "Only the first 100 findings are shown. Run the scan again after reviewing them."))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if integrityAudit.issues.contains(where: { !$0.isSafeToRepair }) {
                        Text("Potential duplicates, mismatched canonical ingredients, and broken links are reported for review; automatic repair only removes redundant references to the same persistent line object.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text(String(localized: "Data integrity"))
        } footer: {
            Text("The scan is non-destructive. Original ingredient text and quantities are shown for review. Safe repair is limited to stale search keys and repeated references to the same persistent recipe-line object; distinct rows are never merged automatically.")
        }
    }

    private func recipeIssueRow(_ issue: IngredientIntegrityIssue) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(issue.canonicalName ?? String(localized: "Unlinked ingredient"))
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text(issue.classification.localizedName)
                    .font(.caption2)
                    .foregroundStyle(issue.classification == .safeAutomaticRepair ? .green : .orange)
            }
            if let rawText = issue.rawText, !rawText.isEmpty {
                Text(rawText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text(issue.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
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
                Text(suggestion.confidence, format: .percent.precision(.fractionLength(0)))
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

    private func repair(_ audit: IngredientIntegrityAudit) {
        guard let household = appState.currentHousehold else { return }
        do {
            let result = try IngredientIntegrityRepairService.repairSafely(audit, in: household, context: context)
            if !result.repairedIssueIDs.isEmpty {
                let undo = context.undoManager
                appState.offerUndo(String(localized: "Recipe integrity repaired")) {
                    undo?.undo()
                    try? context.save()
                }
            }
            integrityAudit = IngredientIntegrityAuditor.audit(household: household, context: context)
        } catch {
            batchErrorMessage = String(localized: "The safe repairs could not be saved.")
            showingBatchError = true
        }
    }

    private func startIntegrityAudit() {
        guard !isAuditingRecipeIngredients, let household = appState.currentHousehold else { return }
        isAuditingRecipeIngredients = true
        Task { @MainActor in
            let audit = await IngredientIntegrityAuditor.auditResponsive(household: household, context: context)
            guard !Task.isCancelled else { return }
            integrityAudit = audit
            isAuditingRecipeIngredients = false
        }
    }

    private func refreshIntegrityAudit() {
        guard let household = appState.currentHousehold else { return }
        Task { @MainActor in
            integrityAudit = await IngredientIntegrityAuditor.auditResponsive(household: household, context: context)
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
        if Ingredient.normalize(suggestion.duplicate.name) == Ingredient.normalize(suggestion.canonical.name) {
            return String(localized: "same name")
        }
        return suggestion.match.reasons.map(reasonName).joined(separator: ", ")
    }

    private var deleteConfirmationTitle: String {
        guard let pendingDeletion else { return String(localized: "Delete ingredient?") }
        return String(localized: "Delete \(pendingDeletion.duplicate.name)?")
    }

    private func deleteImpact(for suggestion: IngredientCleanupSuggestion) -> String {
        let recipeLines = (suggestion.duplicate.dishIngredients ?? []).count
        let shoppingItems = (suggestion.duplicate.shoppingItems ?? []).count
        let aliases = (suggestion.duplicate.aliases ?? []).count
        let stock = IngredientStockMerge.hasData(suggestion.duplicate)
            ? String(localized: "pantry stock")
            : String(localized: "no pantry stock")
        return String(localized: "This match has \(recipeLines) recipe lines, \(shoppingItems) shopping items, \(aliases) aliases, and \(stock). Review the match to keep its links. If deleted, recipe wording, amounts, and shopping items stay but become unlinked. Its aliases, pantry data, and catalogue metadata are removed.")
    }

    private func requestDelete(_ suggestion: IngredientCleanupSuggestion) {
        guard canEditIngredients,
              suggestion.duplicate !== suggestion.canonical,
              let household = suggestion.canonical.household,
              household === suggestion.duplicate.household,
              HouseholdMutationAuthorization.canMutate(household: household)
        else { return }

        // Use the audited merge path when the proposed match has no conflicts,
        // so recipe and shopping-list links survive the duplicate removal.
        if IngredientCleanupService.isSafeForAutomaticMerge(suggestion, in: household) {
            do {
                try IngredientCleanupService.merge(suggestion, context: context)
                offerUndo(String(localized: "Ingredient merged"))
            } catch {
                batchErrorMessage = error.localizedDescription
                showingBatchError = true
            }
            return
        }

        pendingDeletion = suggestion
        showingDeleteConfirmation = true
    }

    private func deleteUnlinked(_ suggestion: IngredientCleanupSuggestion) {
        guard canEditIngredients,
              suggestion.duplicate !== suggestion.canonical,
              let household = suggestion.canonical.household,
              household === suggestion.duplicate.household,
              HouseholdMutationAuthorization.canMutate(household: household)
        else { return }

        let undo = context.undoManager
        undo?.beginUndoGrouping()
        do {
            try IngredientCleanupService.deleteDuplicateKeepingUnlinkedUses(suggestion, context: context)
            undo?.endUndoGrouping()
            offerUndo(String(localized: "Ingredient deleted"))
        } catch {
            undo?.endUndoGrouping()
            undo?.undo()
            try? context.save()
            batchErrorMessage = error.localizedDescription
            showingBatchError = true
        }
        pendingDeletion = nil
    }

    private func offerUndo(_ title: String) {
        let undo = context.undoManager
        appState.offerUndo(title) {
            undo?.undo()
            try? context.save()
        }
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
        guard canEditIngredients else { return }
        let candidates = pendingBatchSuggestions ?? batchSuggestions
        pendingBatchSuggestions = nil
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

    private var canEdit: Bool {
        appState.collaboration.canEdit
            && HouseholdMutationAuthorization.canMutate(household: suggestion.canonical.household)
    }

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
                .disabled(!canEdit || !stockChoices.resolves(suggestion.stockConflicts))
                .accessibilityHint(String(localized: "Moves recipe and shopping list relationships to the canonical ingredient"))

                Button {
                    guard canEdit else { return }
                    IngredientCleanupService.keepSeparate(suggestion)
                    try? context.save()
                    dismiss()
                } label: {
                    Label(String(localized: "Keep separate"), systemImage: "xmark.circle")
                }
                .disabled(!canEdit)
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
        guard canEdit else { return }
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

@MainActor
private struct IngredientRecipeIssueDetailView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    let issue: IngredientIntegrityIssue
    @State private var showingRemovalConfirmation = false
    @State private var errorMessage: String?

    private var household: Household? { appState.currentHousehold }
    private var dish: Dish? {
        guard let household, let dishUUID = issue.dishUUID else { return nil }
        return (household.dishes ?? []).first { $0.uuid == dishUUID }
    }
    private var line: DishIngredient? {
        guard let dish, let lineUUID = issue.dishIngredientUUID else { return nil }
        return (dish.ingredients ?? []).first { $0.uuid == lineUUID }
    }
    private var suggestedIngredient: Ingredient? {
        guard let household, let uuid = issue.suggestedIngredientUUID else { return nil }
        return (household.ingredients ?? []).first { $0.uuid == uuid }
    }
    private var canEdit: Bool {
        appState.collaboration.canEdit
            && HouseholdMutationAuthorization.canMutate(household: household)
    }
    private var canRemoveReviewedLine: Bool {
        issue.kind == .duplicateDishIngredientContent && line != nil && dish != nil && canEdit
    }

    var body: some View {
        Form {
            Section {
                LabeledContent(String(localized: "Classification"), value: issue.classification.localizedName)
                if let dish { LabeledContent(String(localized: "Recipe"), value: dish.name) }
                if let line { LabeledContent(String(localized: "Line ID"), value: line.uuid.uuidString) }
            } header: {
                Text(String(localized: "Finding"))
            }

            Section {
                LabeledContent(String(localized: "Original ingredient text"), value: issue.rawText ?? String(localized: "Not available"))
                LabeledContent(String(localized: "Current canonical ingredient"), value: issue.canonicalName ?? String(localized: "Unlinked"))
                if let value = issue.quantityValue {
                    LabeledContent(String(localized: "Stored quantity"), value: "\(value.formatted(.number)) \(issue.quantityDimensionRaw ?? "")")
                } else {
                    LabeledContent(String(localized: "Stored quantity"), value: String(localized: "Not set"))
                }
            } header: {
                Text(String(localized: "Preserved source data"))
            } footer: {
                Text("Review actions never rewrite the original ingredient text or stored quantity.")
            }

            Section {
                Text(issue.detail)
                    .foregroundStyle(.secondary)
                if !issue.relatedDishIngredientUUIDs.isEmpty {
                    LabeledContent(String(localized: "Related line IDs"), value: issue.relatedDishIngredientUUIDs.map(\.uuidString).joined(separator: ", "))
                }
            } header: {
                Text(String(localized: "Evidence"))
            }

            if let suggestedIngredient, let line, issue.kind == .dishIngredientRawTextMismatch {
                Section {
                    LabeledContent(String(localized: "Suggested canonical ingredient"), value: suggestedIngredient.name)
                    Button {
                        reassign(line, to: suggestedIngredient)
                    } label: {
                        Label(String(localized: "Use suggested ingredient"), systemImage: "arrow.right.circle")
                    }
                    .disabled(!canEdit)
                } header: {
                    Text(String(localized: "Review suggested correction"))
                } footer: {
                    Text("This changes only the canonical relationship. Raw text, quantity, unit, and notes stay unchanged.")
                }
            }

            if canRemoveReviewedLine {
                Section {
                    Button(String(localized: "Remove this duplicate recipe line"), role: .destructive) {
                        showingRemovalConfirmation = true
                    }
                } footer: {
                    Text("Only remove a line after checking that it is not a legitimate repeated ingredient for another preparation section. Undo is available immediately after removal.")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(String(localized: "Recipe ingredient finding"))
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(String(localized: "Done")) { dismiss() }
            }
        }
        .confirmationDialog(
            String(localized: "Remove this recipe line?"),
            isPresented: $showingRemovalConfirmation,
            titleVisibility: .visible
        ) {
            Button(String(localized: "Remove line"), role: .destructive) { removeLine() }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text("The original text and quantity are kept in Undo, but this recipe line will no longer belong to the recipe. Existing shopping and pantry records are not deleted.")
        }
        .alert(String(localized: "Couldn’t update recipe ingredient"), isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button(String(localized: "OK"), role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func reassign(_ line: DishIngredient, to ingredient: Ingredient) {
        guard canEdit else { return }
        do {
            try IngredientIntegrityRepairService.reassignRecipeLine(line, to: ingredient, context: context)
            let undo = context.undoManager
            appState.offerUndo(String(localized: "Canonical ingredient corrected")) {
                undo?.undo()
                try? context.save()
            }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func removeLine() {
        guard canEdit, let dish, let line else { return }
        do {
            try IngredientIntegrityRepairService.removeReviewedDuplicateLine(line, from: dish, context: context)
            let undo = context.undoManager
            appState.offerUndo(String(localized: "Duplicate recipe line removed")) {
                undo?.undo()
                try? context.save()
            }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
