import SwiftUI
import SwiftData
import WebKit

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
    @State private var pendingRecipe: ImportedRecipe?
    @State private var showingReview = false

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
            .sheet(isPresented: $showingReview, onDismiss: { pendingRecipe = nil }) {
                if let pendingRecipe {
                    WebRecipeImportReviewView(recipe: pendingRecipe) { reviewed in
                        apply(reviewed)
                    }
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
            let recipe: ImportedRecipe
            if let html {
                recipe = try await parser.importRecipe(fromHTML: html, sourceURL: url)
            } else {
                recipe = try await parser.importRecipe(from: url)
            }

            guard !recipe.ingredientLines.isEmpty || !(recipe.instructions ?? "").isEmpty else {
                noRecipeFound = true
                return
            }
            if recipe.usedAppleIntelligence {
                // AI-derived data must pass through an editable review before
                // the existing Dish is mutated.
                pendingRecipe = recipe
                showingReview = true
            } else {
                apply(recipe)
            }
        } catch {
            importError = error.localizedDescription
        }
    }

    private func apply(_ recipe: ImportedRecipe) {
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

/// Review step for web imports that needed Apple Intelligence. The model only
/// produces an intermediate value; this view is the last stop before the
/// importer is allowed to touch a Dish.
@MainActor
private struct WebRecipeImportReviewView: View {
    let recipe: ImportedRecipe
    let onSave: (ImportedRecipe) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var ingredients: String
    @State private var instructions: String

    init(recipe: ImportedRecipe, onSave: @escaping (ImportedRecipe) -> Void) {
        self.recipe = recipe
        self.onSave = onSave
        _name = State(initialValue: recipe.name)
        _ingredients = State(initialValue: recipe.ingredientLines.joined(separator: "\n"))
        _instructions = State(initialValue: recipe.instructions ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label(String(localized: "Apple Intelligence recovered part of this recipe."), systemImage: "sparkles")
                        .foregroundStyle(.purple)
                    Text(String(localized: "Check the highlighted fields against the source page before saving."))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section(String(localized: "Review")) {
                    TextField(String(localized: "Recipe name"), text: $name)
                    TextField(String(localized: "Ingredients, one per line"), text: $ingredients, axis: .vertical)
                        .lineLimit(5...14)
                    TextField(String(localized: "Method"), text: $instructions, axis: .vertical)
                        .lineLimit(5...14)
                }

                if let sourceURL = recipe.sourceURL {
                    Section(String(localized: "Source")) {
                        Link(sourceURL.absoluteString, destination: sourceURL)
                            .font(.footnote)
                    }
                }
            }
            .navigationTitle(String(localized: "Review recipe"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel"), role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Use recipe")) {
                        var reviewed = recipe
                        reviewed.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        reviewed.ingredientLines = ingredients.components(separatedBy: .newlines)
                            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                            .filter { !$0.isEmpty }
                        reviewed.instructions = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
                        onSave(reviewed)
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

#Preview {
    RecipeFinderView(dish: PreviewData.dish)
        .modelContainer(PreviewData.container)
}
