import SwiftUI
import SwiftData
import WebKit
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// An in-app browser for finding a recipe for a dish that hasn't got one.
///
/// Opens on a web search for the dish and adds one thing a browser doesn't
/// have: "Use this recipe", which reads the page currently on screen and
/// saves what it finds onto the dish.
@MainActor
struct RecipeFinderView: View {
    @Bindable var dish: Dish
    let initialURL: URL?
    let createsDish: Bool
    let refreshesExisting: Bool

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @AppStorage("search.engine") private var searchEngineRaw = SearchEngine.fallback.rawValue

    @State private var page = WebPage()
    @State private var isImporting = false
    @State private var importError: String?
    @State private var noRecipeFound = false
    @State private var pendingImport: RecipeExtractionResult?

    private var engine: SearchEngine { SearchEngine.resolved(from: searchEngineRaw) }

    init(
        dish: Dish,
        initialURL: URL? = nil,
        createsDish: Bool = false,
        refreshesExisting: Bool = false
    ) {
        self.dish = dish
        self.initialURL = initialURL
        self.createsDish = createsDish
        self.refreshesExisting = refreshesExisting
    }

    /// Only a real web page can be imported — not the search results
    /// themselves, and not an about:blank while the first load is in flight.
    private var importableURL: URL? {
        guard let url = page.url,
              url.scheme?.hasPrefix("http") == true,
              !isSearchResultsPage(url) else { return nil }
        return url
    }

    var body: some View {
        WebView(page)
            .ignoresSafeArea(edges: .bottom)
            .overlay(alignment: .top) { progressBar }
            .navigationTitle(page.title.isEmpty ? String(localized: "Find a recipe") : page.title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { toolbarContent }
            .task {
                guard let url = initialURL ?? RecipeSearch.url(for: dish.name, engine: engine) else { return }
                _ = page.load(url)
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
            .sheet(item: $pendingImport) { result in
                if refreshesExisting {
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
    }

    // MARK: - Chrome

    @ViewBuilder
    private var progressBar: some View {
        if page.isLoading {
            ProgressView(value: page.estimatedProgress)
                .progressViewStyle(.linear)
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button(String(localized: "Cancel"), role: .cancel) { dismiss() }
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
            .disabled(importableURL == nil || isImporting)
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
                if let url = RecipeSearch.url(for: dish.name, engine: engine) { _ = page.load(url) }
            }
        }
    }

    // MARK: - Import

    /// Reads the page as rendered — so cookie walls the user has clicked
    /// through and lazily inserted markup are included — and saves what the
    /// parser can make of it onto the dish.
    private func importCurrentPage() async {
        guard let url = importableURL else { return }
        isImporting = true
        defer { isImporting = false }

        let html = await renderedHTML()
        let parser = RecipeSchemaParser()
        do {
            let result: RecipeExtractionResult
            if let html {
                result = try await parser.importExtraction(fromHTML: html, sourceURL: url)
            } else {
                result = try await parser.importExtraction(from: url)
            }

            guard result.outcome != .failed else {
                noRecipeFound = true
                return
            }
            pendingImport = result
        } catch {
            importError = error.localizedDescription
        }
    }

    private func applyConfirmedRecipe(_ recipe: ImportedRecipe) {
        // A newly discovered dish starts with the search query as its name;
        // the preview's corrected title must win when it is confirmed. An
        // existing dish keeps the name the cook already chose.
        if createsDish, !recipe.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            dish.name = recipe.name.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if createsDish { context.insert(dish) }
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

    /// The live DOM, or nil if the page won't hand it over — the caller then
    /// falls back to fetching the URL fresh.
    private func renderedHTML() async -> String? {
        let result = try? await page.callJavaScript("return document.documentElement.outerHTML")
        return result as? String
    }

    private func saveLinkOnly() {
        guard let url = importableURL else { return }
        if createsDish { context.insert(dish) }
        dish.sourceURL = url
        dish.needsReview = true
        try? context.save()
        dismiss()
    }

    /// True for the engines' own results pages, which have nothing to import.
    private func isSearchResultsPage(_ url: URL) -> Bool {
        guard let host = url.host()?.lowercased() else { return false }
        let engines = ["ecosia.org", "duckduckgo.com", "startpage.com", "google.", "bing.com"]
        return engines.contains { host.contains($0) }
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
    let onSaveLinkOnly: () -> Void
    let onCancel: () -> Void

    init(
        result: RecipeExtractionResult,
        onConfirm: @escaping (ImportedRecipe) -> Void,
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
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Import")) {
                        onConfirm(editedRecipe())
                        dismiss()
                    }
                }
            }
            #if os(iOS)
            .environment(\.editMode, .constant(.active))
            #endif
        }
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

#Preview {
    RecipeFinderView(dish: PreviewData.dish)
        .modelContainer(PreviewData.container)
}
