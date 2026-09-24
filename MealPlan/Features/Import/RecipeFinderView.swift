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

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @AppStorage("search.engine") private var searchEngineRaw = SearchEngine.fallback.rawValue

    @State private var page = WebPage()
    @State private var isImporting = false
    @State private var importError: String?
    @State private var noRecipeFound = false
    @State private var pendingImport: RecipeExtractionResult?

    private var engine: SearchEngine { SearchEngine.resolved(from: searchEngineRaw) }

    init(dish: Dish, initialURL: URL? = nil, createsDish: Bool = false) {
        self.dish = dish
        self.initialURL = initialURL
        self.createsDish = createsDish
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
        DishBuilder.apply(recipe, to: dish, context: context)
        dismiss()
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

#Preview {
    RecipeFinderView(dish: PreviewData.dish)
        .modelContainer(PreviewData.container)
}
