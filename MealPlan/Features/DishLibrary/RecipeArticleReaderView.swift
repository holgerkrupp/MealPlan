import SwiftData
import SwiftUI

/// An article read as a recipe. When the page carries structured recipe data
/// this lays it out the way a saved dish is laid out — photo, times, ingredient
/// list, method — so the decision to keep it is made on the same information.
/// Everything else falls back to the article's own prose.
@MainActor
struct RecipeArticleReaderView: View {
    let article: RecipeArticleContent
    /// Called when reading the page turned up a picture the feed lacked, so a
    /// subscribed feed can keep it. A preview passes nothing.
    var onImageResolved: ((URL?) -> Void)? = nil

    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var context
    @State private var articleText: String?
    @State private var html: String?
    @State private var recipe: ImportedRecipe?
    @State private var loading = true
    @State private var saving = false
    @State private var savedDish: Dish?
    @State private var noRecipeFound = false
    @State private var planningDish: Dish?
    @State private var saveNotice: String?
    @State private var errorMessage: String?
    /// A picture found on the page itself, for an article whose feed had none.
    @State private var resolvedImageURL: URL?

    private var heroImageURL: URL? { article.imageURL ?? resolvedImageURL }

    private var canSave: Bool {
        !loading && !saving && savedDish == nil && !noRecipeFound && recipe != nil && !appState.isGuest
    }

    /// Planning saves first when it has to, so the button stays live for an
    /// unsaved recipe and for one that is already in the library.
    private var canPlan: Bool {
        savedDish != nil || canSave
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                heroImage
                headline

                if loading {
                    ProgressView().frame(maxWidth: .infinity)
                }

                if let saveNotice {
                    Label(saveNotice, systemImage: "checkmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.green)
                }

                if let recipe {
                    tagRow(recipe)
                    timeRow(recipe)
                    Divider()
                    ingredientsSection(recipe)
                    if let instructions = recipe.instructions?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !instructions.isEmpty {
                        Divider()
                        RecipeSection(String(localized: "How to make it")) {
                            Text(instructions)
                                .lineSpacing(5)
                                .textSelection(.enabled)
                        }
                    }
                } else if let articleText {
                    Text(articleText)
                        .font(.body)
                        .lineSpacing(5)
                        .textSelection(.enabled)
                } else if let summary = article.summary {
                    Text(summary).font(.body).lineSpacing(5)
                }

                if let url = article.articleURL {
                    Link(destination: url) {
                        Label(url.host() ?? url.absoluteString, systemImage: "safari")
                    }
                }
            }
            .padding()
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(String(localized: "Recipe article"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                HStack {
                    Button(String(localized: "Plan"), systemImage: "calendar.badge.plus") {
                        Task { await planRecipe() }
                    }
                    .disabled(!canPlan)

                    Button {
                        Task { await saveRecipe() }
                    } label: {
                        if saving { ProgressView() }
                        else if savedDish != nil { Label(String(localized: "Saved"), systemImage: "checkmark.circle") }
                        else if noRecipeFound { Label(String(localized: "No recipe found"), systemImage: "xmark.circle") }
                        else { Label(String(localized: "Save recipe"), systemImage: "square.and.arrow.down") }
                    }
                    .disabled(!canSave)
                }
            }
        }
        .task { await load() }
        .sheet(item: $planningDish) { dish in
            NavigationStack {
                PlanDishSheet(dish: dish, defaultDate: appState.selectedDate)
            }
            .presentationDetents([.medium])
            .dismissesOnOutsideClick()
        }
        .alert(String(localized: "Couldn’t read that page"), isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) {
            Button(String(localized: "OK"), role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
    }

    // MARK: - Layout

    /// The recipe's own photo once the page has been read, and the feed's
    /// thumbnail until then — the picture is on screen while the article
    /// downloads instead of appearing with it.
    @ViewBuilder
    private var heroImage: some View {
        if let data = recipe?.imageData, let image = Image(data: data) {
            image
                .resizable()
                .scaledToFill()
                .frame(height: 220)
                .frame(maxWidth: .infinity)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        } else if heroImageURL != nil {
            GeometryReader { proxy in
                RemoteRecipeImage(
                    url: heroImageURL,
                    tint: DishGlyph.tint(forName: article.title),
                    cornerRadius: 20,
                    width: proxy.size.width,
                    height: 220
                )
            }
            .frame(height: 220)
        }
    }

    private var headline: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(article.title).font(.largeTitle.bold())
            HStack(spacing: 8) {
                if let author = article.author {
                    Text(author)
                }
                if let date = article.publishedAt {
                    Text(date, format: .dateTime.day().month().year())
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func tagRow(_ recipe: ImportedRecipe) -> some View {
        let tags = Array(recipe.tagNames.prefix(6))
        let meals = Array(recipe.mealTypeTags).sorted { $0.rawValue < $1.rawValue }
        if !tags.isEmpty || !meals.isEmpty || recipe.needsReview {
            WrapHStack(spacing: 8) {
                if recipe.needsReview {
                    RecipeBadge(
                        String(localized: "Read from the page"),
                        systemImage: "exclamationmark.triangle.fill",
                        tint: .orange
                    )
                }
                ForEach(meals) { meal in
                    RecipeBadge(meal.localizedName, systemImage: "circle.fill", tint: .accentColor)
                }
                ForEach(tags, id: \.self) { tag in
                    RecipeBadge(tag, systemImage: "tag", tint: .teal)
                }
            }
        }
    }

    @ViewBuilder
    private func timeRow(_ recipe: ImportedRecipe) -> some View {
        if recipe.prepTimeMinutes != nil || recipe.cookTimeMinutes != nil || recipe.servings != nil {
            HStack(spacing: 20) {
                if let prep = recipe.prepTimeMinutes {
                    RecipeMetric(String(localized: "Prep"), "\(prep) min")
                }
                if let cook = recipe.cookTimeMinutes {
                    RecipeMetric(String(localized: "Cook"), "\(cook) min")
                }
                if let servings = recipe.servings {
                    RecipeMetric(String(localized: "Recipe"), String(localized: "\(servings) servings"))
                }
            }
        }
    }

    /// Amounts are the source's own wording. Nothing is rescaled here: the
    /// lines have not been through the unit parser yet, and that only happens
    /// once the recipe is a dish.
    private func ingredientsSection(_ recipe: ImportedRecipe) -> some View {
        RecipeSection(String(localized: "Ingredients")) {
            if recipe.ingredientLines.isEmpty {
                Text(String(localized: "No ingredients added yet."))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(recipe.ingredientLines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 2)
                }
            }
        }
    }

    // MARK: - Actions

    private func load() async {
        RecipeFeedReadState.markRead(article.id)
        guard let url = article.articleURL else {
            loading = false
            return
        }
        do {
            let loaded = try await RecipeArticleCache.shared.articleHTML(for: url)
            html = loaded
            articleText = RecipeArticleText.extract(fromHTML: loaded)
            backfillImage(fromHTML: loaded, sourceURL: url)
            // The page is parsed now rather than on the way out, so the reader
            // can show the recipe itself instead of the prose around it.
            if let parsed = try? await RecipeSchemaParser().importRecipe(fromHTML: loaded, sourceURL: url),
               !parsed.ingredientLines.isEmpty || !(parsed.instructions ?? "").isEmpty {
                recipe = parsed
            } else {
                noRecipeFound = true
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        loading = false
    }

    /// Opening an article pays for the page anyway, so the card it came from
    /// gets its picture out of the same download.
    private func backfillImage(fromHTML html: String, sourceURL: URL) {
        guard heroImageURL == nil else { return }
        let found = RecipeFeedImageResolver.imageURL(inHTML: html, relativeTo: sourceURL)
        resolvedImageURL = found
        onImageResolved?(found)
    }

    private func saveRecipe() async {
        guard savedDish == nil, let recipe else { return }
        saving = true
        defer { saving = false }
        let result = RecipeImportCommitter.importAll(
            [recipe],
            household: appState.currentHousehold,
            createdByName: appState.currentMemberName,
            context: context
        )
        // An article already in the library imports nothing, and planning it
        // still has to reach the dish that is there.
        savedDish = result.dishes.first ?? existingDish(for: recipe)
        // Deliberately not `appState.importNotice`: that raises an alert owned
        // by RootView, and presenting one dismisses any sheet above it — which
        // took the subscribe sheet's site preview with it. The notice belongs
        // to this screen, so this screen shows it.
        saveNotice = result.imported > 0
            ? String(localized: "Saved to your recipes.")
            : String(localized: "Already in your recipes.")
    }

    /// Planning saves the recipe first when it has to. Neither step closes this
    /// screen — a site worth one recipe is usually worth two.
    private func planRecipe() async {
        if savedDish == nil { await saveRecipe() }
        planningDish = savedDish
    }

    private func existingDish(for recipe: ImportedRecipe) -> Dish? {
        let dishes = (try? context.fetch(FetchDescriptor<Dish>())) ?? []
        if let source = recipe.sourceURL?.absoluteString ?? article.articleURL?.absoluteString,
           let match = dishes.first(where: { $0.sourceURLString == source }) {
            return match
        }
        return dishes.first { $0.name.localizedCaseInsensitiveCompare(recipe.name) == .orderedSame }
    }
}
