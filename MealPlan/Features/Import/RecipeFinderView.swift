import SwiftUI
import SwiftData
import WebKit
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// An in-app browser for finding a recipe on the web.
///
/// Opens on a web search with the person's chosen engine and adds one thing a
/// browser doesn't have: "Use this recipe", which reads the page currently on
/// screen and offers what it finds for review. It works in two ways:
///
/// * **For a dish** (`init(dish:…)`) — find a recipe for a dish that hasn't
///   got one, or refresh one from its source. The result is saved onto that
///   dish.
/// * **For the library** (`init(query:planningContext:…)`) — free-text search
///   from Discover. Nothing exists in the store until the person confirms a
///   recipe; it then goes through `RecipeImportCommitter` (so the same page
///   tried twice is found, not duplicated) and, for *Save & plan*, onto the
///   planning context's day and meal — or into `PlanDishSheet` when the search
///   was not started from a slot. Cancelling leaves nothing behind.
@MainActor
struct RecipeFinderView: View {
    let dish: Dish?
    let initialURL: URL?
    let refreshesExisting: Bool
    let planningContext: RecipePlanningContext?

    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.finishRecipePlanning) private var finishPlanning
    @AppStorage("search.engine") private var searchEngineRaw = SearchEngine.fallback.rawValue

    @State private var page = WebPage()
    @State private var searchText: String
    @State private var isImporting = false
    @State private var importError: String?
    @State private var noRecipeFound = false
    @State private var pendingImport: RecipeExtractionResult?
    /// Library mode: a dish saved by *Save & plan* waiting for the review
    /// sheet to finish dismissing before `PlanDishSheet` goes up.
    @State private var dishToPlanAfterReview: Dish?
    @State private var planningDish: Dish?
    @State private var savedAnything = false
    @State private var saveNotice: String?
    @State private var saveError: String?

    private var engine: SearchEngine { SearchEngine.resolved(from: searchEngineRaw) }

    /// Free-text search from Discover: no dish exists until one is confirmed.
    private var isLibraryMode: Bool { dish == nil }

    init(
        dish: Dish,
        initialURL: URL? = nil,
        refreshesExisting: Bool = false
    ) {
        self.dish = dish
        self.initialURL = initialURL
        self.refreshesExisting = refreshesExisting
        self.planningContext = nil
        _searchText = State(initialValue: dish.name)
    }

    /// A web search for whatever was typed, saving into the library. Pass
    /// `planningContext` when the search was started for a particular day and
    /// meal, and `initialURL` to open a site instead of a search.
    init(
        query: String,
        planningContext: RecipePlanningContext? = nil,
        initialURL: URL? = nil
    ) {
        self.dish = nil
        self.initialURL = initialURL
        self.refreshesExisting = false
        self.planningContext = planningContext
        _searchText = State(initialValue: query)
    }

    private var importableURL: URL? { SearchEngine.importableURL(page.url) }

    private var currentSearchURL: URL? {
        isLibraryMode
            ? RecipeSearch.url(forFreeText: searchText, engine: engine)
            : RecipeSearch.url(for: searchText, engine: engine)
    }

    private var canImport: Bool {
        importableURL != nil && !isImporting && !(isLibraryMode && appState.isGuest)
    }

    var body: some View {
        WebView(page)
            .ignoresSafeArea(edges: .bottom)
            .overlay(alignment: .top) { progressBar }
            .overlay(alignment: .bottom) { saveNoticeBanner }
            .navigationTitle(page.title.isEmpty ? String(localized: "Find a recipe") : page.title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .modifier(EditableWebSearch(isEnabled: isLibraryMode, text: $searchText, onSubmit: runSearch))
            .toolbar { toolbarContent }
            .task {
                guard let url = initialURL ?? currentSearchURL else { return }
                _ = page.load(url)
            }
            .task(id: saveNotice) {
                guard let saveNotice else { return }
                AccessibilityNotification.Announcement(saveNotice).post()
                try? await Task.sleep(for: .seconds(4))
                if !Task.isCancelled { self.saveNotice = nil }
            }
            .alert(
                String(localized: "Couldn’t read that page"),
                isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })
            ) {
                Button(String(localized: "Save link only")) { saveLinkOnly() }
                Button(String(localized: "Cancel"), role: .cancel) {}
            } message: {
                Text(importError ?? "")
            }
            .alert(
                String(localized: "No recipe found on that page"),
                isPresented: $noRecipeFound
            ) {
                Button(String(localized: "Save link only")) { saveLinkOnly() }
                Button(String(localized: "Keep looking"), role: .cancel) {}
            } message: {
                Text("Open the page with the actual recipe on it, then try again.")
            }
            .alert(
                String(localized: "Couldn’t save the recipe"),
                isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })
            ) {
                Button(String(localized: "OK"), role: .cancel) {}
            } message: {
                Text(saveError ?? "")
            }
            .sheet(item: $pendingImport, onDismiss: presentPendingPlan) { result in
                reviewSheet(for: result)
            }
            .detailPresentation(item: $planningDish, route: { .planRecipe($0.uuid) }) { dish in
                NavigationStack {
                    PlanDishSheet(dish: dish, defaultDate: appState.selectedDate)
                }
                .presentationDetents([.medium, .large])
                .dismissesOnOutsideClick()
            }
    }

    @ViewBuilder
    private func reviewSheet(for result: RecipeExtractionResult) -> some View {
        if refreshesExisting, let dish {
            RecipeRefreshPreview(
                result: result,
                dish: dish,
                onApply: { recipe, selection in
                    do {
                        try DishBuilder.refresh(recipe, to: dish, context: context, selection: selection)
                        pendingImport = nil
                        dismiss()
                    } catch {
                        importError = String(localized: "The refreshed recipe could not be saved. Your existing recipe was kept. Try again.")
                    }
                },
                onCancel: { pendingImport = nil }
            )
        } else if isLibraryMode {
            RecipeImportPreview(
                result: result,
                onConfirm: { recipe in
                    pendingImport = nil
                    saveToLibrary(recipe, andPlan: false)
                },
                onConfirmAndPlan: { recipe in
                    pendingImport = nil
                    saveToLibrary(recipe, andPlan: true)
                },
                onSaveLinkOnly: {
                    pendingImport = nil
                    saveLinkOnly()
                },
                onCancel: { pendingImport = nil }
            )
        } else {
            RecipeImportPreview(
                result: result,
                onConfirm: { recipe in
                    pendingImport = nil
                    applyConfirmedRecipe(recipe)
                },
                onSaveLinkOnly: {
                    pendingImport = nil
                    saveLinkOnly()
                },
                onCancel: { pendingImport = nil }
            )
        }
    }

    // MARK: - Chrome

    @ViewBuilder
    private var progressBar: some View {
        if page.isLoading {
            ProgressView(value: page.estimatedProgress)
                .progressViewStyle(.linear)
        }
    }

    @ViewBuilder
    private var saveNoticeBanner: some View {
        if let saveNotice {
            Label(saveNotice, systemImage: "checkmark.circle.fill")
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
                .padding(.bottom, 24)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            if isLibraryMode && savedAnything {
                Button(String(localized: "Done")) { dismiss() }
            } else {
                Button(String(localized: "Cancel"), role: .cancel) { dismiss() }
            }
        }

        ToolbarItem(placement: .confirmationAction) {
            Button {
                Task { await importCurrentPage() }
            } label: {
                if isImporting {
                    ProgressView()
                } else {
                    Label(String(localized: "Use this recipe"), systemImage: "square.and.arrow.down")
                }
            }
            .disabled(!canImport)
        }

        ToolbarItemGroup(placement: .navigation) {
            Button(String(localized: "Back"), systemImage: "chevron.backward") {
                if let item = page.backForwardList.backList.last { _ = page.load(item) }
            }
            .disabled(page.backForwardList.backList.isEmpty)

            Button(String(localized: "Forward"), systemImage: "chevron.forward") {
                if let item = page.backForwardList.forwardList.first { _ = page.load(item) }
            }
            .disabled(page.backForwardList.forwardList.isEmpty)

            Button(String(localized: "Search again"), systemImage: "magnifyingglass") {
                runSearch()
            }
            .disabled(currentSearchURL == nil)

            Button(String(localized: "Open website"), systemImage: "safari") {
                if let url = page.url, url.scheme?.hasPrefix("http") == true { openURL(url) }
            }
            .disabled(page.url?.scheme?.hasPrefix("http") != true)
        }
    }

    /// Runs only on an explicit Search / Return / "Search again" — never per
    /// keystroke.
    private func runSearch() {
        if let url = currentSearchURL { _ = page.load(url) }
    }

    // MARK: - Import

    /// Reads the page as rendered — so cookie walls the user has clicked
    /// through and lazily inserted markup are included — and offers what the
    /// parser can make of it for review.
    private func importCurrentPage() async {
        guard let url = importableURL else { return }
        isImporting = true
        defer { isImporting = false }

        let html = await renderedHTML()
        let parser = RecipeSchemaParser()
        do {
            var result: RecipeExtractionResult
            if let html {
                result = try await parser.importExtraction(fromHTML: html, sourceURL: url)
            } else {
                result = try await parser.importExtraction(from: url)
            }

            guard result.outcome != .failed else {
                noRecipeFound = true
                return
            }
            result.recipe = RecipeSearch.attributed(result.recipe, to: url)
            pendingImport = result
        } catch {
            importError = error.localizedDescription
        }
    }

    private func applyConfirmedRecipe(_ recipe: ImportedRecipe) {
        // An existing dish keeps the name the cook already chose.
        guard let dish else { return }
        if refreshesExisting {
            do {
                try DishBuilder.refresh(recipe, to: dish, context: context)
                dismiss()
            } catch {
                importError = String(localized: "The refreshed recipe could not be saved. Your existing recipe was kept. Try again.")
            }
        } else {
            DishBuilder.apply(recipe, to: dish, context: context)
            dismiss()
        }
    }

    /// Library mode: the one way a found recipe enters the store. The
    /// committer's duplicate check makes a second try of the same page reuse
    /// the dish already there, and planning is idempotent per day and meal.
    private func saveToLibrary(_ recipe: ImportedRecipe, andPlan: Bool) {
        let result = RecipeImportCommitter.importAll(
            [recipe],
            household: appState.currentHousehold,
            createdByName: appState.currentMemberName,
            context: context
        )
        guard !result.persistenceFailed, let saved = result.dishesForPlanning.first else {
            saveError = result.summary
            return
        }
        savedAnything = true
        // A local notice, not `appState.importNotice`: the root alert would
        // tear down this sheet (and any sheet it was opened from).
        saveNotice = result.imported > 0
            ? String(localized: "Saved to your recipes.")
            : String(localized: "Already in your recipes.")

        guard andPlan else { return }
        if let planningContext {
            switch MealPlanner.planOnce(
                dish: saved,
                on: planningContext.date,
                mealKey: planningContext.mealKey,
                household: appState.currentHousehold,
                memberName: appState.currentMemberName,
                context: context
            ) {
            case .saved, .alreadyPlanned:
                // Back to the slot the search was started for. Opened from
                // Discover-for-a-slot, that closes Discover too.
                if let finishPlanning { finishPlanning() } else { dismiss() }
            case .failed:
                saveError = String(localized: "The recipe is in your recipes, but it couldn’t be added to the plan. Try planning it again.")
            }
        } else {
            dishToPlanAfterReview = saved
        }
    }

    /// The plan sheet goes up only once the review sheet is fully gone —
    /// presenting while another sheet is still dismissing is dropped on iOS.
    private func presentPendingPlan() {
        guard let dish = dishToPlanAfterReview else { return }
        dishToPlanAfterReview = nil
        planningDish = dish
    }

    /// The live DOM, or nil if the page won't hand it over — the caller then
    /// falls back to fetching the URL fresh.
    private func renderedHTML() async -> String? {
        let result = try? await page.callJavaScript("return document.documentElement.outerHTML")
        return result as? String
    }

    private func saveLinkOnly() {
        guard let url = importableURL else { return }
        guard let dish else {
            saveToLibrary(RecipeSearch.linkOnlyRecipe(title: page.title, url: url), andPlan: false)
            return
        }
        dish.sourceURL = url
        dish.needsReview = true
        try? context.save()
        dismiss()
    }
}

/// The finder's own editable search field, for free-text search only: a
/// dish-bound search keeps searching for the dish.
private struct EditableWebSearch: ViewModifier {
    let isEnabled: Bool
    @Binding var text: String
    let onSubmit: () -> Void

    func body(content: Content) -> some View {
        if isEnabled {
            content
                .searchable(text: $text, prompt: Text(String(localized: "Search the web for recipes")))
                .onSubmit(of: .search, onSubmit)
        } else {
            content
        }
    }
}

/// A confirmation boundary for web extraction. Editing this value is entirely
/// local state; ingredient canonicalization and SwiftData writes only happen
/// in `onConfirm`.
@MainActor
struct RecipeImportPreview: View {
    @Environment(\.dismiss) private var dismiss
    @State private var recipe: ImportedRecipe
    @State private var servingsText: String
    @State private var prepTimeText: String
    @State private var cookTimeText: String

    let outcome: RecipeExtractionOutcome
    let warnings: [String]
    let provenance: [RecipeExtractionField: RecipeExtractionProvenance]
    let onConfirm: (ImportedRecipe) -> Void
    /// Set for a library import: the confirm button becomes "Save recipe"
    /// and a second one saves and plans. Nil keeps the dish-bound "Import".
    let onConfirmAndPlan: ((ImportedRecipe) -> Void)?
    let onSaveLinkOnly: () -> Void
    let onCancel: () -> Void

    init(
        result: RecipeExtractionResult,
        onConfirm: @escaping (ImportedRecipe) -> Void,
        onConfirmAndPlan: ((ImportedRecipe) -> Void)? = nil,
        onSaveLinkOnly: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        _recipe = State(initialValue: result.recipe)
        _servingsText = State(initialValue: result.recipe.servings.map(String.init) ?? "")
        _prepTimeText = State(initialValue: result.recipe.prepTimeMinutes.map(String.init) ?? "")
        _cookTimeText = State(initialValue: result.recipe.cookTimeMinutes.map(String.init) ?? "")
        outcome = result.outcome
        warnings = result.warnings
        provenance = result.provenance
        self.onConfirm = onConfirm
        self.onConfirmAndPlan = onConfirmAndPlan
        self.onSaveLinkOnly = onSaveLinkOnly
        self.onCancel = onCancel
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(String(localized: "Recipe title"), text: $recipe.name)
                    if let host = recipe.sourceURL?.host() {
                        LabeledContent(
                            String(localized: "Source"),
                            value: host.replacingOccurrences(of: "www.", with: "")
                        )
                    }
                    if let image = imageView {
                        image
                            .resizable()
                            .scaledToFill()
                            .frame(maxWidth: .infinity)
                            .frame(height: 150)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    Text(sourceLabel(for: .title))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text(String(localized: "Recipe"))
                }

                if !warnings.isEmpty {
                    Section {
                        ForEach(warnings, id: \.self) { warning in
                            Label(warning, systemImage: "exclamationmark.circle")
                                .font(.callout)
                        }
                    } header: {
                        Text(outcome == .partial
                             ? String(localized: "Needs review")
                             : String(localized: "Import warning"))
                    }
                }

                Section(String(localized: "Details")) {
                    TextField(String(localized: "Servings"), text: $servingsText)
                    TextField(String(localized: "Prep time (minutes)"), text: $prepTimeText)
                    TextField(String(localized: "Cook time (minutes)"), text: $cookTimeText)
                }

                Section {
                    ForEach(recipe.ingredientLines.indices, id: \.self) { index in
                        TextField(
                            String(localized: "Ingredient"),
                            text: Binding(
                                get: { recipe.ingredientLines[index] },
                                set: { recipe.ingredientLines[index] = $0 }
                            )
                        )
                    }
                    .onDelete { recipe.ingredientLines.remove(atOffsets: $0) }
                    .onMove { recipe.ingredientLines.move(fromOffsets: $0, toOffset: $1) }
                    Button {
                        recipe.ingredientLines.append("")
                    } label: {
                        Label(String(localized: "Add ingredient"), systemImage: "plus")
                    }
                } header: {
                    HStack {
                        Text(String(localized: "Ingredients"))
                        Spacer()
                        Text(sourceLabel(for: .ingredients))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    TextEditor(text: Binding(
                        get: { recipe.instructions ?? "" },
                        set: { recipe.instructions = $0 }
                    ))
                    .frame(minHeight: 150)
                } header: {
                    HStack {
                        Text(String(localized: "Instructions"))
                        Spacer()
                        Text(sourceLabel(for: .instructions))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(String(localized: "Review recipe"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel"), role: .cancel) {
                        onCancel()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .secondaryAction) {
                    Button(String(localized: "Save link only")) {
                        onSaveLinkOnly()
                        dismiss()
                    }
                }
                if let onConfirmAndPlan {
                    ToolbarItem(placement: .primaryAction) {
                        Button(String(localized: "Save & plan"), systemImage: "calendar.badge.plus") {
                            onConfirmAndPlan(editedRecipe())
                            dismiss()
                        }
                        .disabled(!hasTitle)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(String(localized: "Save recipe")) {
                            onConfirm(editedRecipe())
                            dismiss()
                        }
                        .disabled(!hasTitle)
                    }
                } else {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(String(localized: "Import")) {
                            onConfirm(editedRecipe())
                            dismiss()
                        }
                    }
                }
            }
            #if os(iOS)
            .environment(\.editMode, .constant(.active))
            #endif
        }
    }

    /// A library dish needs a name; the dish-bound import keeps the dish's own.
    private var hasTitle: Bool {
        !recipe.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func editedRecipe() -> ImportedRecipe {
        var edited = recipe
        edited.name = edited.name.trimmingCharacters(in: .whitespacesAndNewlines)
        edited.ingredientLines = edited.ingredientLines.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        edited.instructions = edited.instructions?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        edited.servings = Int(servingsText.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0 > 0 ? $0 : nil }
        edited.prepTimeMinutes = Int(prepTimeText.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0 > 0 ? $0 : nil }
        edited.cookTimeMinutes = Int(cookTimeText.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0 > 0 ? $0 : nil }
        edited.needsReview = outcome != .good || edited.needsReview
        return edited
    }

    private func sourceLabel(for field: RecipeExtractionField) -> String {
        switch provenance[field] {
        case .jsonLD, .microdata, .embeddedJSON:
            return String(localized: "Read from structured recipe data")
        case .semanticHTML:
            return String(localized: "Read from visible page")
        case .appleIntelligence:
            return String(localized: "Read on device")
        case .userEdited:
            return String(localized: "Edited")
        case nil:
            return String(localized: "Not found")
        }
    }

    private var imageView: Image? {
        guard let data = recipe.imageData else { return nil }
        #if canImport(UIKit)
        return UIImage(data: data).map(Image.init(uiImage:))
        #elseif canImport(AppKit)
        return NSImage(data: data).map(Image.init(nsImage:))
        #else
        return nil
        #endif
    }
}

/// A conservative refresh review. Existing content is shown beside the
/// fetched candidate and only explicitly selected fields reach DishBuilder.
@MainActor
struct RecipeRefreshPreview: View {
    @Environment(\.dismiss) private var dismiss
    @State private var recipe: ImportedRecipe
    @State private var selection: DishBuilder.RefreshSelection
    @State private var servingsText: String
    @State private var prepTimeText: String
    @State private var cookTimeText: String

    let dish: Dish
    let outcome: RecipeExtractionOutcome
    let warnings: [String]
    let duplicateIndices: Set<Int>
    let onApply: (ImportedRecipe, DishBuilder.RefreshSelection) -> Void
    let onCancel: () -> Void

    init(
        result: RecipeExtractionResult,
        dish: Dish,
        onApply: @escaping (ImportedRecipe, DishBuilder.RefreshSelection) -> Void,
        onCancel: @escaping () -> Void
    ) {
        _recipe = State(initialValue: result.recipe)
        _selection = State(initialValue: DishBuilder.RefreshSelection.conservative(for: dish, result: result))
        _servingsText = State(initialValue: result.recipe.servings.map(String.init) ?? "")
        _prepTimeText = State(initialValue: result.recipe.prepTimeMinutes.map(String.init) ?? "")
        _cookTimeText = State(initialValue: result.recipe.cookTimeMinutes.map(String.init) ?? "")
        self.dish = dish
        outcome = result.outcome
        warnings = result.warnings
        duplicateIndices = DishBuilder.suspiciousDuplicateIngredientIndices(result.recipe)
        self.onApply = onApply
        self.onCancel = onCancel
    }

    var body: some View {
        NavigationStack {
            Form {
                if outcome != .good || !warnings.isEmpty {
                    Section {
                        Label(
                            String(localized: "Review the source carefully before applying changes."),
                            systemImage: "exclamationmark.triangle"
                        )
                        ForEach(warnings, id: \.self) { warning in
                            Text(warning).font(.callout)
                        }
                    } header: {
                        Text(String(localized: "Needs review"))
                    }
                }

                Section(String(localized: "Recipe title")) {
                    Toggle(String(localized: "Use fetched title"), isOn: $selection.title)
                    comparison(current: dish.name, proposed: recipe.name)
                }

                Section(String(localized: "Ingredients")) {
                    Toggle(String(localized: "Use fetched ingredients"), isOn: $selection.ingredients)
                    LabeledContent(String(localized: "Current"), value: String(localized: "\(dish.sortedIngredients.count) lines"))
                    LabeledContent(String(localized: "Fetched"), value: String(localized: "\(ingredientCount) lines"))
                    if duplicateIndices.isEmpty == false {
                        Label(
                            String(localized: "\(duplicateIndices.count) exact repeat(s) need review. Different quantities or notes are kept separate."),
                            systemImage: "exclamationmark.circle"
                        )
                        .font(.callout)
                        .foregroundStyle(.orange)
                    }
                    ForEach(Array(ingredientLines.enumerated()), id: \.offset) { index, line in
                        HStack {
                            Text(line)
                            if duplicateIndices.contains(index) {
                                Image(systemName: "exclamationmark.circle.fill")
                                    .foregroundStyle(.orange)
                                    .accessibilityLabel(String(localized: "Repeated ingredient; review before applying"))
                            }
                        }
                    }
                }

                Section(String(localized: "Instructions")) {
                    Toggle(String(localized: "Use fetched instructions"), isOn: $selection.instructions)
                    comparison(
                        current: dish.recipeText ?? String(localized: "No instructions"),
                        proposed: recipe.instructions ?? String(localized: "No instructions")
                    )
                }

                Section(String(localized: "Yield and timing")) {
                    Toggle(String(localized: "Use fetched servings"), isOn: $selection.servings)
                    TextField(String(localized: "Fetched servings"), text: $servingsText)
                        #if os(iOS)
                        .keyboardType(.numberPad)
                        #endif
                    Toggle(String(localized: "Use fetched prep time"), isOn: $selection.prepTime)
                    TextField(String(localized: "Fetched prep minutes"), text: $prepTimeText)
                        #if os(iOS)
                        .keyboardType(.numberPad)
                        #endif
                    Toggle(String(localized: "Use fetched cook time"), isOn: $selection.cookTime)
                    TextField(String(localized: "Fetched cook minutes"), text: $cookTimeText)
                        #if os(iOS)
                        .keyboardType(.numberPad)
                        #endif
                    LabeledContent(String(localized: "Current yield"), value: dish.yieldText)
                }

                if recipe.nutritionPerServing != nil {
                    Section(String(localized: "Nutrition")) {
                        Toggle(String(localized: "Use fetched nutrition"), isOn: $selection.nutrition)
                        Text(String(localized: "Existing nutrition stays unchanged unless selected."))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                Section(String(localized: "Source")) {
                    Toggle(String(localized: "Save verified source link"), isOn: $selection.sourceURL)
                    Text(recipe.sourceURL?.absoluteString ?? String(localized: "No verified source link"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .navigationTitle(String(localized: "Review refresh"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel"), role: .cancel) {
                        onCancel()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Apply selected")) {
                        onApply(editedRecipe(), selection)
                        dismiss()
                    }
                    .disabled(!hasSelection)
                }
            }
        }
    }

    private var ingredientLines: [String] {
        if let structured = recipe.structuredIngredients {
            return structured.map { $0.rawText ?? $0.name }
        }
        return recipe.ingredientLines
    }

    private var ingredientCount: Int { ingredientLines.count }

    private var hasSelection: Bool {
        selection.title || selection.ingredients || selection.instructions || selection.servings
            || selection.prepTime || selection.cookTime || selection.nutrition || selection.sourceURL
    }

    @ViewBuilder
    private func comparison(current: String, proposed: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(localized: "Current: \(current)"))
                .foregroundStyle(.secondary)
            Text(String(localized: "Fetched: \(proposed)"))
        }
        .font(.callout)
    }

    private func editedRecipe() -> ImportedRecipe {
        var edited = recipe
        edited.name = edited.name.trimmingCharacters(in: .whitespacesAndNewlines)
        edited.instructions = edited.instructions?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        edited.servings = Int(servingsText.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0 > 0 ? $0 : nil }
        edited.prepTimeMinutes = Int(prepTimeText.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0 > 0 ? $0 : nil }
        edited.cookTimeMinutes = Int(cookTimeText.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0 > 0 ? $0 : nil }
        return edited
    }
}

@MainActor
struct RecipeSourceEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    let onSubmit: (URL) -> Void

    init(initialText: String, onSubmit: @escaping (URL) -> Void) {
        _text = State(initialValue: initialText)
        self.onSubmit = onSubmit
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(String(localized: "Recipe website URL"), text: $text)
                        #if os(iOS)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                } footer: {
                    Text(String(localized: "MealPlan tries HTTPS first. A failed fetch never changes the saved recipe."))
                }
            }
            .navigationTitle(String(localized: "Change source"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel"), role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Fetch")) {
                        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
                              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
                              url.host != nil else { return }
                        onSubmit(url)
                    }
                    .disabled(URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines))?.host == nil)
                }
            }
        }
    }
}

#Preview("For a dish") {
    NavigationStack { RecipeFinderView(dish: PreviewData.dish) }
        .environment(AppState.preview)
        .modelContainer(PreviewData.container)
}

#Preview("Free-text search") {
    NavigationStack { RecipeFinderView(query: "neapolitanische Pizza") }
        .environment(AppState.preview)
        .modelContainer(PreviewData.container)
}
