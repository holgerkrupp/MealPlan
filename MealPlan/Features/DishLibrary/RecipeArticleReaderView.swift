import SwiftData
import SwiftUI
import os

/// An article read as a recipe. When the page carries structured recipe data
/// this lays it out the way a saved dish is laid out — photo, times, ingredient
/// list, method — so the decision to keep it is made on the same information.
/// Everything else falls back to the article's own prose.
@MainActor
struct RecipeArticleReaderView: View {
    let article: RecipeArticleContent
    var onRead: (() -> Void)? = nil
    /// Called when reading the page turned up a picture the feed lacked, so a
    /// subscribed feed can keep it. A preview passes nothing.
    var onImageResolved: ((URL?) -> Void)? = nil

    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var context
    /// Set when Discover was opened from a meal slot: *Plan this meal* then
    /// lands the recipe there and closes Discover.
    @Environment(\.recipePlanningContext) private var planningContext
    @Environment(\.finishRecipePlanning) private var finishPlanning
    @Query private var mealTypes: [MealType]
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
    @State private var planError: String?
    /// The article handed to the in-app browser's extractor, for a page whose
    /// recipe could not be read here.
    @State private var importTarget: ArticleImportTarget?
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

    /// The page was read and holds nothing that can honestly become a dish.
    private var showsFallback: Bool {
        !loading && savedDish == nil && recipe == nil && article.articleURL != nil
    }

    private var planningText: String? {
        guard let planningContext else { return nil }
        let name = MealType.isExtra(planningContext.mealKey)
            ? MealType.extraName
            : mealTypes.first { $0.key == planningContext.mealKey }?.name ?? ""
        return RecipePlanningContextLabel.text(day: planningContext.date, mealName: name)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                #if os(iOS)
                FullPageScreenshotBridge()
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
                #endif

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
        // Within thumb's reach rather than in the navigation bar.
        .safeAreaInset(edge: .bottom) { actionBar }
        #else
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if showsFallback {
                    readOnWebsiteButton
                    tryImportingButton
                } else {
                    saveButton
                    planButton
                }
            }
        }
        #endif
        .task { await load() }
        .task(id: saveNotice) {
            guard let saveNotice else { return }
            AccessibilityNotification.Announcement(saveNotice).post()
        }
        .detailPresentation(
            item: $importTarget,
            route: { .browseSite(url: $0.url, title: article.title, planningContext: planningContext) }
        ) { target in
            NavigationStack {
                RecipeFinderView(query: "", planningContext: planningContext, initialURL: target.url)
            }
            .dismissesOnOutsideClick()
        }
        .alert(String(localized: "Couldn’t plan the recipe"), isPresented: Binding(
            get: { planError != nil }, set: { if !$0 { planError = nil } }
        )) {
            Button(String(localized: "OK"), role: .cancel) {}
        } message: { Text(planError ?? "") }
        .detailPresentation(item: $planningDish, route: { .planRecipe($0.uuid) }) { dish in
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

    // MARK: - Actions bar

    /// Save and Plan for a readable recipe; for a page with none, the honest
    /// alternatives — the site itself, or the browser's own extractor.
    @ViewBuilder
    private var actionBar: some View {
        if !appState.isGuest || showsFallback {
            VStack(spacing: 8) {
                if showsFallback {
                    Text(String(localized: "Meals couldn’t find a recipe it can save on this page."))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                } else if let planningText {
                    Label(planningText, systemImage: "calendar")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { actionButtons }
                    VStack(spacing: 8) { actionButtons }
                }
                .controlSize(.large)
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(.bar)
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        if showsFallback {
            readOnWebsiteButton
                .buttonStyle(.bordered)
            if !appState.isGuest {
                tryImportingButton
                    .buttonStyle(.borderedProminent)
            }
        } else {
            saveButton
                .buttonStyle(.bordered)
            planButton
                .buttonStyle(.borderedProminent)
        }
    }

    private var saveButton: some View {
        Button {
            Task { await saveRecipe() }
        } label: {
            Group {
                if saving { ProgressView() }
                else if savedDish != nil { Label(String(localized: "Saved"), systemImage: "checkmark.circle") }
                else { Label(String(localized: "Save recipe"), systemImage: "square.and.arrow.down") }
            }
            .frame(maxWidth: .infinity)
        }
        .labelStyle(.titleAndIcon)
        .disabled(!canSave)
    }

    private var planButton: some View {
        Button {
            Task { await planRecipe() }
        } label: {
            Label(String(localized: "Plan this meal"), systemImage: "calendar.badge.plus")
                .frame(maxWidth: .infinity)
        }
        .labelStyle(.titleAndIcon)
        .disabled(!canPlan)
        .accessibilityHint(planningText.map { String(localized: "Saves the recipe and plans it for \($0)") }
                           ?? String(localized: "Saves the recipe and lets you pick a day"))
    }

    @ViewBuilder
    private var readOnWebsiteButton: some View {
        if let url = article.articleURL {
            Link(destination: url) {
                Label(String(localized: "Read on website"), systemImage: "safari")
                    .frame(maxWidth: .infinity)
            }
            .labelStyle(.titleAndIcon)
        }
    }

    @ViewBuilder
    private var tryImportingButton: some View {
        if let url = article.articleURL {
            Button {
                importTarget = ArticleImportTarget(url: url)
            } label: {
                Label(String(localized: "Try importing"), systemImage: "square.and.arrow.down.on.square")
                    .frame(maxWidth: .infinity)
            }
            .labelStyle(.titleAndIcon)
            .accessibilityHint(String(localized: "Opens the page in Meals’ browser to read the recipe from it"))
        }
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
                if let sourceName = article.sourceName {
                    Text(sourceName)
                }
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
                if recipe.usedAppleIntelligence {
                    RecipeBadge(
                        String(localized: "Apple Intelligence recovered fields"),
                        systemImage: "sparkles",
                        tint: .purple
                    )
                }
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
            let yieldLabel = recipe.yieldUnitRaw == "pieces"
                ? recipe.yieldLabel ?? String(localized: "pieces")
                : String(localized: "servings")
            HStack(spacing: 20) {
                if let prep = recipe.prepTimeMinutes {
                    RecipeMetric(String(localized: "Prep"), "\(prep) min")
                }
                if let cook = recipe.cookTimeMinutes {
                    RecipeMetric(String(localized: "Cook"), "\(cook) min")
                }
                if let servings = recipe.servings {
                    RecipeMetric(String(localized: "Recipe"), "\(servings) \(yieldLabel)")
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
        let signpost = RecipePerformanceSignposts.signposter.beginInterval("article navigation")
        defer { RecipePerformanceSignposts.signposter.endInterval("article navigation", signpost) }
        RecipeFeedReadState.markRead(article.readStateID)
        onRead?()
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
               isUsableRecipe(parsed) {
                recipe = parsed
            } else {
                noRecipeFound = true
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        loading = false
    }

    /// Heuristic HTML is allowed to supplement ingredients, but instructions
    /// alone are too easy to confuse with CSS, signup forms or page chrome.
    /// Structured recipes (`needsReview == false`) remain trusted when a site
    /// legitimately publishes steps without an ingredient list.
    private func isUsableRecipe(_ recipe: ImportedRecipe) -> Bool {
        if !recipe.ingredientLines.isEmpty { return true }
        let hasInstructions = recipe.instructions?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty == false
        return !recipe.needsReview && hasInstructions
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
        guard !result.persistenceFailed else {
            errorMessage = result.summary
            return
        }
        savedDish = result.dishesForPlanning.first
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
        guard let dish = savedDish else { return }
        guard let planningContext else {
            planningDish = dish
            return
        }
        // Idempotent: planning the same recipe into the same slot twice
        // leaves one entry.
        switch MealPlanner.planOnce(
            dish: dish,
            on: planningContext.date,
            mealKey: planningContext.mealKey,
            household: appState.currentHousehold,
            memberName: appState.currentMemberName,
            context: context
        ) {
        case .saved, .alreadyPlanned:
            if let finishPlanning {
                // Back to the plan, where the dish now sits in its slot.
                finishPlanning()
            } else {
                saveNotice = String(localized: "Planned for \(planningText ?? "")")
            }
        case .failed:
            planError = String(localized: "The recipe is in your recipes, but it couldn’t be added to the plan. Try planning it again.")
        }
    }

}

/// Identity from the value, so a redraw never re-presents the browser.
private struct ArticleImportTarget: Identifiable, Hashable {
    let url: URL
    var id: URL { url }
}
