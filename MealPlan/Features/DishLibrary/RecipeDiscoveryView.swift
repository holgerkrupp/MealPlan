import SwiftData
import SwiftUI

@MainActor
struct RecipeDiscoveryView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var context
    @Query(sort: \RecipeFeed.dateAdded) private var allFeeds: [RecipeFeed]
    @Query(sort: \RecipeBookmark.title) private var allBookmarks: [RecipeBookmark]

    @State private var showingSubscription = false
    @State private var showingBookmark = false
    @State private var browserTarget: BookmarkBrowserTarget?
    @State private var refreshing = false

    /// The same measurements the dish library uses, so an article card and a
    /// dish card line up when both are on screen on the same iPad.
    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 240), spacing: 16)]

    private var feeds: [RecipeFeed] {
        allFeeds.filter { $0.household?.uuid == appState.currentHousehold?.uuid }
    }

    private var bookmarks: [RecipeBookmark] {
        allBookmarks.filter { $0.household?.uuid == appState.currentHousehold?.uuid }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20, pinnedViews: [.sectionHeaders]) {
                if feeds.isEmpty && bookmarks.isEmpty { discoveryEmptyState }
                ForEach(feeds) { feed in
                    Section {
                        feedBody(feed)
                    } header: {
                        feedHeader(feed)
                    }
                }
                if !bookmarks.isEmpty { bookmarksSection }
            }
            .padding(.vertical)
        }
        .navigationTitle(String(localized: "Discover recipes"))
        .refreshable { await refresh(force: true) }
        .toolbar {
            if !appState.isGuest {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button(String(localized: "Subscribe to a site"), systemImage: "dot.radiowaves.left.and.right") {
                            showingSubscription = true
                        }
                        Button(String(localized: "Add recipe site"), systemImage: "bookmark") {
                            showingBookmark = true
                        }
                    } label: {
                        Label(String(localized: "Add"), systemImage: "plus")
                    }
                }
            }
        }
        .overlay { if refreshing { ProgressView().controlSize(.large) } }
        .task { await refresh(force: false) }
        .sheet(isPresented: $showingSubscription) {
            FeedSubscriptionSheet()
        }
        .sheet(isPresented: $showingBookmark) {
            RecipeBookmarkSheet()
        }
        .sheet(item: $browserTarget) { target in
            NavigationStack {
                RecipeFinderView(dish: target.dish, initialURL: target.url, createsDish: true)
            }
            .dismissesOnOutsideClick()
        }
    }

    private var discoveryEmptyState: some View {
        ContentUnavailableView {
            Label(String(localized: "Find something good"), systemImage: "newspaper")
        } description: {
            Text(String(localized: "Subscribe to a recipe blog or bookmark a site your household likes."))
        } actions: {
            if !appState.isGuest {
                Button(String(localized: "Subscribe to a site")) { showingSubscription = true }
                    .buttonStyle(.borderedProminent)
            }
        }
        // Outside a List it has to claim the width itself, or it hugs the
        // leading edge of the stack.
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    @ViewBuilder
    private func feedBody(_ feed: RecipeFeed) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if feed.sortedItems.isEmpty {
                Text(String(localized: "No posts yet."))
                    .foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(feed.sortedItems.prefix(20)) { item in
                        NavigationLink {
                            RecipeArticleReaderView(item: item)
                        } label: {
                            RecipeArticleCard(item: item)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            feedFooter(feed)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
    }

    private func feedHeader(_ feed: RecipeFeed) -> some View {
        HStack {
            Text(feed.title)
                .font(.title3.weight(.semibold))
                .lineLimit(1)
            Spacer()
            if let site = feed.siteURL {
                Link(destination: site) { Image(systemName: "safari") }
                    .accessibilityLabel(String(localized: "Open website"))
            }
            if !appState.isGuest {
                Menu {
                    Button(String(localized: "Delete feed"), role: .destructive) {
                        context.delete(feed)
                        try? context.save()
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel(String(localized: "Feed options"))
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        // A pinned header slides over the cards behind it, so it needs a
        // ground of its own to stay readable.
        .background(.bar)
    }

    @ViewBuilder
    private func feedFooter(_ feed: RecipeFeed) -> some View {
        if feed.hasBeenMissingForFortnight {
            Label(String(localized: "This feed has been unavailable for two weeks."), systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        } else if feed.consecutiveFailures > 0 {
            Text(String(localized: "Refresh will retry later."))
        } else if let fetched = feed.lastFetchedAt {
            Text(String(localized: "Updated \(fetched.formatted(date: .abbreviated, time: .shortened))"))
        }
    }

    /// Bookmarked sites have no artwork to make a card out of, so they stay a
    /// row of chips under the articles rather than pretending to be dishes.
    private var bookmarksSection: some View {
        Section {
            WrapHStack(spacing: 8) {
                ForEach(bookmarks) { bookmark in
                    Button {
                        open(bookmark)
                    } label: {
                        Label(bookmark.title, systemImage: "bookmark")
                            .font(.subheadline)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(.quaternary, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        if !appState.isGuest {
                            Button(String(localized: "Delete"), role: .destructive) {
                                context.delete(bookmark)
                                try? context.save()
                            }
                        }
                    }
                }
            }
            .padding(.horizontal)
        } header: {
            Text(String(localized: "Recipe sites"))
                .font(.title3.weight(.semibold))
                .padding(.horizontal)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.bar)
        }
    }

    private func refresh(force: Bool) async {
        guard !appState.isGuest else { return }
        refreshing = true
        await RecipeFeedService.refreshAll(context: context, force: force)
        refreshing = false
    }

    private func open(_ bookmark: RecipeBookmark) {
        guard let url = bookmark.url else { return }
        let dish = Dish(name: bookmark.title)
        dish.household = appState.currentHousehold
        dish.createdByName = appState.currentMemberName
        browserTarget = BookmarkBrowserTarget(dish: dish, url: url)
    }
}

private struct BookmarkBrowserTarget: Identifiable {
    let id = UUID()
    let dish: Dish
    let url: URL
}

/// An article read as a recipe. When the page carries structured recipe data
/// this lays it out the way a saved dish is laid out — photo, times, ingredient
/// list, method — so the decision to keep it is made on the same information.
/// Everything else falls back to the article's own prose.
@MainActor
private struct RecipeArticleReaderView: View {
    let item: RecipeFeedItem

    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var context
    @State private var articleText: String?
    @State private var html: String?
    @State private var recipe: ImportedRecipe?
    @State private var loading = true
    @State private var saving = false
    @State private var savedDish: Dish?
    @State private var noRecipeFound = false
    @State private var showingPlanSheet = false
    @State private var errorMessage: String?

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
                } else if let summary = item.summary {
                    Text(summary).font(.body).lineSpacing(5)
                }

                if let url = item.url {
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
        .sheet(isPresented: $showingPlanSheet) {
            if let savedDish {
                NavigationStack {
                    PlanDishSheet(dish: savedDish, defaultDate: appState.selectedDate)
                }
                .presentationDetents([.medium])
                .dismissesOnOutsideClick()
            }
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
        } else if item.imageURL != nil {
            GeometryReader { proxy in
                RemoteRecipeImage(
                    url: item.imageURL,
                    tint: DishGlyph.tint(forName: item.title),
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
            Text(item.title).font(.largeTitle.bold())
            HStack(spacing: 8) {
                if let author = item.author {
                    Text(author)
                }
                if let date = item.publishedAt {
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
        RecipeFeedReadState.markRead(item.stableID)
        guard let url = item.url else {
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
        guard item.imageURL == nil else { return }
        if let found = RecipeFeedImageResolver.imageURL(inHTML: html, relativeTo: sourceURL) {
            item.imageURLString = found.absoluteString
        }
        item.imageLookupAt = .now
        try? context.save()
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
        appState.importNotice = result.summary
    }

    private func planRecipe() async {
        if savedDish == nil { await saveRecipe() }
        guard savedDish != nil else { return }
        showingPlanSheet = true
    }

    private func existingDish(for recipe: ImportedRecipe) -> Dish? {
        let dishes = (try? context.fetch(FetchDescriptor<Dish>())) ?? []
        if let source = recipe.sourceURL?.absoluteString ?? item.url?.absoluteString,
           let match = dishes.first(where: { $0.sourceURLString == source }) {
            return match
        }
        return dishes.first { $0.name.localizedCaseInsensitiveCompare(recipe.name) == .orderedSame }
    }
}

@MainActor
private struct FeedSubscriptionSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var allFeeds: [RecipeFeed]
    @State private var address = ""
    @State private var subscribing = false
    @State private var pendingSuggestion: String?
    @State private var errorMessage: String?

    /// Sites already subscribed to drop out of the list, so the section shrinks
    /// as the household works through it instead of offering duplicates.
    private var suggestions: [RecipeFeedSuggestion] {
        let subscribed = Set(allFeeds.flatMap { [$0.siteURL, $0.feedURL] }.compactMap(Self.host))
        return RecipeFeedSuggestions.suggestions().filter {
            guard let host = Self.host($0.url) else { return true }
            return !subscribed.contains(host)
        }
    }

    private static func host(_ url: URL?) -> String? {
        guard let host = url?.host()?.lowercased() else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(String(localized: "Website address"), text: $address)
                        .textContentType(.URL)
                    #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                    #endif
                } footer: {
                    Text(String(localized: "MealPlan finds the site’s RSS, Atom or JSON feed automatically."))
                }

                if !suggestions.isEmpty {
                    Section {
                        ForEach(suggestions) { suggestion in
                            suggestionRow(suggestion)
                        }
                    } header: {
                        Text(String(localized: "Suggestions"))
                    } footer: {
                        Text(String(localized: "Recipe sites near you that publish a feed."))
                    }
                }
            }
            .navigationTitle(String(localized: "Subscribe to a site"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Subscribe")) { Task { await subscribeToTypedAddress() } }
                        .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty || subscribing)
                }
            }
            .alert(String(localized: "Couldn’t subscribe"), isPresented: Binding(
                get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
            )) {
                Button(String(localized: "OK"), role: .cancel) {}
            } message: { Text(errorMessage ?? "") }
        }
        .presentationDetents([.medium, .large])
    }

    private func suggestionRow(_ suggestion: RecipeFeedSuggestion) -> some View {
        Button {
            Task { await subscribe(to: suggestion) }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(suggestion.name).font(.headline)
                    Text(suggestion.detail).font(.subheadline).foregroundStyle(.secondary)
                    Text(suggestion.displayHost).font(.caption).foregroundStyle(.tertiary)
                }
                .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                if pendingSuggestion == suggestion.id {
                    ProgressView()
                } else {
                    Image(systemName: "plus.circle")
                        .foregroundStyle(Color.accentColor)
                        .imageScale(.large)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(subscribing)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(String(localized: "Subscribe to \(suggestion.name)")))
        .accessibilityHint(Text(suggestion.detail))
    }

    private func subscribeToTypedAddress() async {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed.contains("://") ? trimmed : "https://\(trimmed)") else {
            errorMessage = RecipeFeedParserError.invalidURL.localizedDescription
            return
        }
        if await subscribe(to: url) { dismiss() }
    }

    /// Stays open after a suggestion: the row disappears from the list, which is
    /// confirmation enough, and most households add two or three in one sitting.
    private func subscribe(to suggestion: RecipeFeedSuggestion) async {
        guard let url = suggestion.url else { return }
        pendingSuggestion = suggestion.id
        _ = await subscribe(to: url)
        pendingSuggestion = nil
    }

    @discardableResult
    private func subscribe(to url: URL) async -> Bool {
        subscribing = true
        defer { subscribing = false }
        do {
            _ = try await RecipeFeedService.subscribe(to: url, household: appState.currentHousehold, context: context)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}

@MainActor
private struct RecipeBookmarkSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var address = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField(String(localized: "Name"), text: $title)
                TextField(String(localized: "Website address"), text: $address)
                    .textContentType(.URL)
                #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                #endif
            }
            .navigationTitle(String(localized: "Add recipe site"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Add")) { save() }
                        .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || address.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func save() {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed.contains("://") ? trimmed : "https://\(trimmed)") else { return }
        let bookmark = RecipeBookmark(title: title.trimmingCharacters(in: .whitespacesAndNewlines), url: url)
        bookmark.household = appState.currentHousehold
        context.insert(bookmark)
        try? context.save()
        dismiss()
    }
}
