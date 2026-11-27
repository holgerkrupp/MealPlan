import SwiftData
import SwiftUI
import os

@MainActor
struct RecipeDiscoveryView: View {
    /// The day and meal Discover was opened for, if any. An online search
    /// carries it into the browser so *Save & plan* lands in that slot.
    var planningContext: RecipePlanningContext? = nil

    @Environment(AppState.self) private var appState

    var body: some View {
        let householdID = appState.currentHousehold?.uuid
        RecipeDiscoveryContent(householdID: householdID, planningContext: planningContext)
            .id(householdID)
    }
}

@MainActor
private struct RecipeDiscoveryContent: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var context
    @Query private var feeds: [RecipeFeed]
    @Query private var bookmarks: [RecipeBookmark]
    let householdID: UUID?
    let planningContext: RecipePlanningContext?
    @AppStorage("search.engine") private var searchEngineRaw = SearchEngine.fallback.rawValue

    @State private var showingSubscription = false
    @State private var showingBookmark = false
    @State private var browserTarget: BookmarkBrowserTarget?
    @State private var webSearch: RecipeWebSearchRequest?
    @State private var refreshing = false
    @State private var loadingDiscovery = true
    @State private var loadingSeasonal = false
    @State private var discoveredSources: [RecipeDiscoverySourceResult] = []
    @State private var failedDiscoverySources: [String] = []
    @State private var selectedCategory: RecipeDiscoveryCategory?
    @State private var surpriseArticle: RecipeArticleContent?
    @State private var search = ""
    @State private var sort: RecipeArticleSort = .mixed
    @State private var scope: RecipeArticleScope = .current
    /// nil means built-in and subscribed sources together.
    @State private var sourceFilter: String?
    @State private var snapshot = RecipeDiscoverySnapshot.empty
    /// The curated top of the page, built with the snapshot off the main actor.
    @State private var inspiration = DiscoveryInspiration.empty
    /// Changes when one of the value-only snapshot inputs changes. Keeping a
    /// generation avoids rebuilding a task key from every cached article.
    @State private var snapshotInputRevision = 0
    @State private var seasonalCollections: [SeasonalRecipeCollection] = []
    @State private var seasonalReadIDs: Set<String> = []
    @State private var seasonalRoute: SeasonalRecipeMomentRoute?
    @State private var seasonalRefreshRevision = 0
    @State private var completedSeasonalRefreshRevision = 0
    @State private var completedSeasonalContextKey = ""
    @State private var nextSeasonalTransition: Date?

    init(householdID: UUID?, planningContext: RecipePlanningContext?) {
        self.householdID = householdID
        self.planningContext = planningContext
        let scopedHouseholdID = householdID ?? UUID()
        _feeds = Query(FetchDescriptor<RecipeFeed>(
            predicate: #Predicate { $0.household?.uuid == scopedHouseholdID },
            sortBy: [SortDescriptor(\RecipeFeed.dateAdded)]
        ))
        _bookmarks = Query(FetchDescriptor<RecipeBookmark>(
            predicate: #Predicate { $0.household?.uuid == scopedHouseholdID },
            sortBy: [SortDescriptor(\RecipeBookmark.title)]
        ))
    }

    private var subscribedSites: [SubscribedSite] {
        feeds.compactMap { feed in
            guard let url = feed.siteURL ?? feed.feedURL else { return nil }
            return SubscribedSite(id: feed.uuid, name: feed.title, url: url)
        }
    }

    private var sourceOptions: [DiscoverySourceOption] {
        RecipeDiscoveryService.sources.map {
            DiscoverySourceOption(id: "discovery:\($0.id)", name: $0.name, siteURL: $0.siteURL)
        } + feeds.map {
            DiscoverySourceOption(id: "feed:\($0.uuid.uuidString)", name: $0.title, siteURL: $0.siteURL)
        }
    }

    private var discoveryMarketContext: RecipeDiscoveryMarketContext {
        let household = appState.currentHousehold
        let identifier = household?.localeIdentifier ?? Locale.current.identifier
        return RecipeDiscoveryMarketContext(
            locale: Locale(identifier: identifier),
            unitSystem: household?.presentationUnitSystem
        )
    }

    /// True while the view is showing less than everything it has, which is
    /// what the empty state and the toolbar badge key off.
    private var isFiltering: Bool {
        !search.trimmingCharacters(in: .whitespaces).isEmpty
            || scope != .current
            || sourceFilter != nil
            || selectedCategory != nil
    }

    private var hasVisibleArticles: Bool { !snapshot.visibleArticles.isEmpty }

    private var trimmedSearch: String { search.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View { chrome(scrollContent) }

    private var scrollContent: some View {
        ScrollView {
            #if os(iOS)
            FullPageScreenshotBridge()
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
            #endif

            LazyVStack(alignment: .leading, spacing: 20, pinnedViews: [.sectionHeaders]) {
                if let planningContext {
                    planningBanner(planningContext)
                        .padding(.horizontal, MacLayout.gutter)
                }
                if !trimmedSearch.isEmpty {
                    searchOnlineRow
                        .padding(.horizontal, MacLayout.gutter)
                }
                if loadingDiscovery && snapshot.allArticles.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                } else if snapshot.allArticles.isEmpty && bookmarks.isEmpty && subscribedSites.isEmpty
                            && SeasonalRecipeShelfPolicy.overviewCollections(seasonalCollections).isEmpty
                            && !loadingSeasonal {
                    discoveryEmptyState
                } else if isFiltering && !hasVisibleArticles {
                    noMatchesEmptyState
                }
                // The curated top steps aside while a search is typed: the
                // matches and "Search online" are what the cook wants then.
                if trimmedSearch.isEmpty {
                    if !inspiration.themes.isEmpty {
                        inspirationLanding
                            .padding(.horizontal, MacLayout.gutter)
                    }
                    if !inspiration.weekIdeas.isEmpty {
                        weekIdeasSection
                    }
                    if !subscribedSites.isEmpty {
                        fromYourSitesSection
                    }
                    seasonalShelves
                }
                if hasVisibleArticles {
                    articleSection
                }
                if !bookmarks.isEmpty && !isFiltering { bookmarksSection }
            }
            .padding(.vertical)
        }
    }

    @ViewBuilder
    private var seasonalShelves: some View {
        ForEach(SeasonalRecipeShelfPolicy.overviewCollections(seasonalCollections)) { collection in
            SeasonalRecipeShelf(
                title: collection.moment.localizedTitle,
                symbolName: collection.moment.symbolName ?? "leaf",
                articles: collection.articles,
                readIDs: seasonalReadIDs,
                onSeeAll: { seasonalRoute = SeasonalRecipeShelfPolicy.route(for: collection) },
                onRead: markRead,
                onImageResolved: { article, imageURL in
                    recordSeasonalImage(imageURL: imageURL, forArticle: article)
                }
            )
        }
    }

    private func chrome<V: View>(_ view: V) -> some View {
        view
        .navigationTitle(String(localized: "Discover recipes"))
        .refreshable { await refresh(force: true) }
        .searchable(
            text: $search,
            prompt: Text(String(localized: "Search for dishes, ingredients or ideas"))
        )
        // Typing filters what Discover already has, locally. Only an explicit
        // Search / Return goes online.
        .onSubmit(of: .search) { searchOnline() }
        .toolbar {
            ToolbarItem(placement: .secondaryAction) { browsingMenu }
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
        .task(id: seasonalRefreshTaskID) {
            guard seasonalRefreshRevision > 0 else { return }
            let contextKey = seasonalContextKey
            if seasonalRefreshRevision == completedSeasonalRefreshRevision,
               contextKey == completedSeasonalContextKey,
               let nextSeasonalTransition,
               nextSeasonalTransition > .now {
                do {
                    try await Task.sleep(for: .seconds(max(1, Int(nextSeasonalTransition.timeIntervalSinceNow))))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
            }
            await refreshSeasonal()
        }
        .task(id: snapshotTaskID) { await rebuildSnapshot() }
        .onReceive(NotificationCenter.default.publisher(for: .mealPlanDataDidChange)) { _ in
            // Sync and other store writers can update feed items without
            // changing the parent feed's scalar fields.
            snapshotInputRevision &+= 1
            seasonalRefreshRevision &+= 1
        }
        .detailPresentation(isPresented: $showingSubscription, route: .subscribeToSite) {
            FeedSubscriptionSheet()
        }
        .detailPresentation(isPresented: $showingBookmark, route: .addRecipeSite) {
            RecipeBookmarkSheet()
        }
        .detailPresentation(
            item: $browserTarget,
            route: { .browseSite(url: $0.url, title: $0.title, planningContext: planningContext) }
        ) { target in
            NavigationStack {
                RecipeFinderView(query: "", planningContext: planningContext, initialURL: target.url)
            }
            .dismissesOnOutsideClick()
        }
        .detailPresentation(
            item: $webSearch,
            route: { .searchWeb(query: $0.query, planningContext: $0.planningContext) }
        ) { request in
            NavigationStack {
                RecipeFinderView(query: request.query, planningContext: request.planningContext)
            }
        }
        .navigationDestination(item: $surpriseArticle) { article in
            reader(for: article)
        }
        .navigationDestination(item: $seasonalRoute) { route in
            SeasonalRecipeMomentGrid(
                title: route.title,
                symbolName: route.symbolName,
                articles: route.articles,
                readIDs: seasonalReadIDs,
                onRead: markRead,
                onImageResolved: { article, imageURL in
                    recordSeasonalImage(imageURL: imageURL, forArticle: article)
                }
            )
        }
    }

    /// Always offered while there is a query, whether or not Discover has
    /// matches of its own: the web is bigger than any list of sources.
    private var searchOnlineRow: some View {
        let engine = SearchEngine.resolved(from: searchEngineRaw)
        return Button(action: searchOnline) {
            HStack(spacing: 12) {
                Image(systemName: "globe")
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "Search online for “\(trimmedSearch)”"))
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                    Text(String(localized: "Searches the whole web with \(engine.localizedName), inside Meals."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.top, 4)
    }

    private func searchOnline() {
        guard !trimmedSearch.isEmpty else { return }
        webSearch = RecipeWebSearchRequest(query: trimmedSearch, planningContext: planningContext)
    }

    private var discoveryEmptyState: some View {
        ContentUnavailableView {
            Label(String(localized: "Find something good"), systemImage: "newspaper")
        } description: {
            Text(String(localized: "Recipe sources are unavailable right now. You can still subscribe to a blog or bookmark a site your household likes."))
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

    // MARK: - Curated top

    private func planningBanner(_ planningContext: RecipePlanningContext) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(String(localized: "Finding something new for"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            RecipePlanningContextLabel(planningContext: planningContext)
                .font(.headline)
            Text(String(localized: "Open a recipe and choose Plan this meal to add it there."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    /// "What sounds good today?": a handful of honest starting points. A
    /// choice opens its own grid, so Back is the way out.
    private var inspirationLanding: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(localized: "What sounds good today?"))
                .font(.title2.bold())
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 280), spacing: 12)], spacing: 12) {
                ForEach(inspiration.themes) { choice in
                    InspirationThemeTile(choice: choice) {
                        seasonalRoute = SeasonalRecipeMomentRoute(
                            momentID: "theme:\(choice.theme.rawValue)",
                            title: choice.theme.localizedTitle,
                            symbolName: choice.theme.symbolName,
                            articles: choice.articles
                        )
                    }
                }
            }
        }
    }

    private var weekIdeasSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            shelfHeader(
                String(localized: "Ideas for this week"),
                symbol: "sparkles",
                caption: String(localized: "Fresh recipes from different sites")
            )
            .padding(.horizontal, MacLayout.gutter)

            if let hero = inspiration.weekIdeas.first {
                let heroContent = content(hero)
                NavigationLink {
                    reader(for: heroContent)
                } label: {
                    RecipeArticleHeroCard(article: heroContent) { url in
                        record(imageURL: url, forArticle: heroContent)
                    }
                }
                .buttonStyle(.plain)
                .frame(maxWidth: 720)
                .padding(.horizontal, MacLayout.gutter)
            }
            articleRow(Array(inspiration.weekIdeas.dropFirst()))
        }
    }

    /// Unread recipes from followed sites, with the sites themselves as
    /// chips underneath. Shown only once something is followed.
    private var fromYourSitesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                shelfHeader(
                    String(localized: "New from your sites"),
                    symbol: "dot.radiowaves.left.and.right",
                    caption: String(localized: "Unread, from the sites you follow")
                )
                Spacer(minLength: 8)
                if !inspiration.allFromYourSites.isEmpty {
                    Button(String(localized: "See all")) {
                        seasonalRoute = SeasonalRecipeMomentRoute(
                            momentID: "followed-sites",
                            title: String(localized: "New from your sites"),
                            symbolName: "dot.radiowaves.left.and.right",
                            articles: inspiration.allFromYourSites
                        )
                    }
                    .font(.subheadline.weight(.semibold))
                    .buttonStyle(.borderless)
                    .accessibilityLabel(String(localized: "See all new recipes from your sites"))
                }
            }
            .padding(.horizontal, MacLayout.gutter)

            if inspiration.fromYourSites.isEmpty {
                Text(String(localized: "You’re all caught up."))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, MacLayout.gutter)
            } else {
                articleRow(inspiration.fromYourSites)
            }

            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(subscribedSites) { site in
                        Link(destination: site.url) {
                            Label(site.name, systemImage: "safari")
                                .font(.subheadline.weight(.medium))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(.quaternary, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint(String(localized: "Open website"))
                    }
                }
                .padding(.horizontal, MacLayout.gutter)
            }
            .scrollIndicators(.hidden)
        }
    }

    private func shelfHeader(_ title: String, symbol: String, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(title, systemImage: symbol)
                .font(.title3.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// The same horizontal row of cards the seasonal shelf draws.
    @ViewBuilder
    private func articleRow(_ articles: [RecipeDiscoveryArticle]) -> some View {
        if !articles.isEmpty {
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(articles) { article in
                        let item = content(article)
                        NavigationLink {
                            reader(for: item)
                        } label: {
                            RecipeArticleCard(article: item) { url in
                                record(imageURL: url, forArticle: item)
                            }
                        }
                        .frame(width: 174)
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, MacLayout.gutter)
            }
            .scrollIndicators(.hidden)
        }
    }

    private func reader(for article: RecipeArticleContent) -> some View {
        RecipeArticleReaderView(article: article, onRead: {
            markRead(article)
        }) { url in
            record(imageURL: url, forArticle: article)
        }
    }

    private var articleSection: some View {
        Section {
            categoryBrowser
                .padding(.horizontal, MacLayout.gutter)

            RecipeArticleGrid(
                articles: snapshot.visibleArticles.map(content),
                onImageResolved: { article, url in
                    record(imageURL: url, forArticle: article)
                }
            ) { article in
                reader(for: article)
            }
            .padding(.horizontal, MacLayout.gutter)

            discoveryStatus
                .padding(.horizontal, MacLayout.gutter)
        } header: {
            HStack {
                Text(sourceFilter.flatMap { selected in
                    sourceOptions.first(where: { $0.id == selected })?.name
                } ?? (trimmedSearch.isEmpty
                      ? String(localized: "Explore all recipes")
                      : String(localized: "Matches in Discover and your sites")))
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                if let source = sourceFilter.flatMap({ selected in
                    sourceOptions.first(where: { $0.id == selected })
                }), let siteURL = source.siteURL {
                    Link(destination: siteURL) { Image(systemName: "safari") }
                        .accessibilityLabel(String(localized: "Open website"))
                }
            }
            .padding(.horizontal, MacLayout.gutter)
            .padding(.vertical, 8)
            .background(.bar)
        }
    }

    private var categoryBrowser: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(String(localized: "Browse by category"), systemImage: "square.grid.2x2")
                    .font(.headline)
                Spacer()
                Button(String(localized: "Surprise me"), systemImage: "dice") {
                    surpriseArticle = snapshot.visibleArticles.randomElement().map(content)
                }
                .buttonStyle(.bordered)
                .disabled(snapshot.visibleArticles.isEmpty)
            }

            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    categoryButton(nil, title: String(localized: "All recipes"), symbol: "square.grid.2x2")
                    ForEach(snapshot.availableCategories) { category in
                        categoryButton(category, title: category.localizedName, symbol: category.symbolName)
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
    }

    private func categoryButton(
        _ category: RecipeDiscoveryCategory?,
        title: String,
        symbol: String
    ) -> some View {
        let selected = selectedCategory == category
        return Button {
            selectedCategory = category
        } label: {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .foregroundStyle(selected ? Color.white : Color.primary)
                .background(selected ? Color.accentColor : Color.secondary.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder
    private var discoveryStatus: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !failedDiscoverySources.isEmpty {
                Label(
                    String(localized: "Some sources could not be refreshed: \(failedDiscoverySources.joined(separator: ", "))."),
                    systemImage: "exclamationmark.triangle"
                )
                .foregroundStyle(.orange)
            }
            ForEach(feeds.filter { $0.hasBeenMissingForFortnight }) { feed in
                Label(
                    String(localized: "\(feed.title) has been unavailable for two weeks."),
                    systemImage: "exclamationmark.triangle"
                )
                .foregroundStyle(.orange)
            }
            if let latest = feeds.compactMap(\.lastFetchedAt).max() {
                Text(String(localized: "Subscriptions updated \(latest.formatted(date: .abbreviated, time: .shortened))"))
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .padding(.top, 4)
    }

    private func remove(_ feed: RecipeFeed) {
        if sourceFilter == "feed:\(feed.uuid.uuidString)" {
            sourceFilter = nil
        }
        context.delete(feed)
        try? context.save()
    }

    private var subscriptionManagementMenu: some View {
        Menu(String(localized: "Subscriptions"), systemImage: "dot.radiowaves.left.and.right") {
            ForEach(feeds) { feed in
                Button(String(localized: "Remove \(feed.title)"), systemImage: "trash", role: .destructive) {
                    remove(feed)
                }
            }
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
            .padding(.horizontal, MacLayout.gutter)
        } header: {
            Text(String(localized: "Recipe sites"))
                .font(.title3.weight(.semibold))
                .padding(.horizontal, MacLayout.gutter)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.bar)
        }
    }

    private var browsingMenu: some View {
        Menu {
            Picker(String(localized: "Show"), selection: $scope) {
                ForEach(RecipeArticleScope.allCases) { scope in
                    Text(scope.localizedName).tag(scope)
                }
            }
            Picker(String(localized: "Sort by"), selection: $sort) {
                ForEach(RecipeArticleSort.allCases) { sort in
                    Text(sort.localizedName).tag(sort)
                }
            }
            if sourceOptions.count > 1 {
                Picker(String(localized: "Source"), selection: $sourceFilter) {
                    Text(String(localized: "All sources")).tag(String?.none)
                    ForEach(sourceOptions) { source in
                        Text(source.name).tag(String?.some(source.id))
                    }
                }
            }
            if !feeds.isEmpty && !appState.isGuest {
                Divider()
                subscriptionManagementMenu
            }
        } label: {
            Label(
                String(localized: "Sort and filter"),
                systemImage: isFiltering
                    ? "line.3.horizontal.decrease.circle.fill"
                    : "line.3.horizontal.decrease.circle"
            )
        }
    }

    private var noMatchesEmptyState: some View {
        ContentUnavailableView {
            Label(String(localized: "Nothing matches"), systemImage: "magnifyingglass")
        } description: {
            Text(String(localized: "Try another word, or widen the filter to include older posts."))
        } actions: {
            Button(String(localized: "Clear filters")) {
                search = ""
                scope = .current
                sourceFilter = nil
                selectedCategory = nil
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    private var snapshotTaskID: String {
        // This key contains only small UI state and a monotonic generation.
        // In particular, do not walk feed items or public articles from body.
        return "\(search)|\(scope.rawValue)|\(sort.rawValue)|\(sourceFilter ?? "*")|\(selectedCategory?.rawValue ?? "*")|\(feeds.count)|\(snapshotInputRevision)"
    }

    private var seasonalContextKey: String {
        let market = discoveryMarketContext
        return "\(market.regionCode ?? "*")|\(market.languageCode ?? "*")|\(market.unitSystem.rawValue)"
    }

    private var seasonalRefreshTaskID: String {
        let transition = nextSeasonalTransition?.timeIntervalSince1970 ?? 0
        return "\(seasonalRefreshRevision)|\(seasonalContextKey)|\(transition)"
    }

    private var discoveryQuery: RecipeDiscoveryQuery {
        RecipeDiscoveryQuery(
            search: search,
            scope: scope,
            sourceID: sourceFilter,
            category: selectedCategory,
            sort: sort
        )
    }

    private func rebuildSnapshot() async {
        let signpost = RecipePerformanceSignposts.signposter.beginInterval("discovery snapshot")
        defer { RecipePerformanceSignposts.signposter.endInterval("discovery snapshot", signpost) }
        let seeds = makeDiscoverySeeds()
        let subscribedSourceOrder = feeds.map { "feed:\($0.uuid.uuidString)" }
        let marketContext = discoveryMarketContext
        let query = discoveryQuery
        let readIDs = RecipeFeedReadState.readIDs()
        let seasonal = seasonalCollections
        let (next, nextInspiration) = await Task.detached(priority: .userInitiated) {
            let sourceOrder = RecipeDiscoveryService.sources(for: marketContext).map { "discovery:\($0.id)" }
                + subscribedSourceOrder
            let lowAffinity = RecipeDiscoveryService.lowAffinitySourceIDs(for: marketContext)
            let built = RecipeDiscoverySnapshot.build(
                seeds: seeds,
                sourceOrder: sourceOrder,
                query: query,
                readIDs: readIDs,
                lowAffinitySourceIDs: lowAffinity
            )
            return (built, Self.makeInspiration(built.allArticles, lowAffinity: lowAffinity, seasonal: seasonal))
        }.value
        guard !Task.isCancelled else { return }
        snapshot = next
        inspiration = nextInspiration
    }

    /// The shelves skip whatever "In season" already shows, and the seasonal
    /// choice offers every active moment's recipes.
    private nonisolated static func makeInspiration(
        _ articles: [RecipeDiscoveryArticle],
        lowAffinity: Set<String>,
        seasonal: [SeasonalRecipeCollection]
    ) -> DiscoveryInspiration {
        let onShelf = SeasonalRecipeShelfPolicy.overviewCollections(seasonal)
        return DiscoveryInspirationPolicy.make(
            articles: articles,
            lowAffinitySourceIDs: lowAffinity,
            excludingIDs: Set(onShelf.flatMap { $0.articles.map(\.id) }),
            seasonalArticles: DiscoveryInspirationPolicy.seasonalArticles(seasonal)
        )
    }

    /// Seasonal collections arrive after the snapshot; re-pick the shelves
    /// from the articles already built rather than rebuilding the snapshot.
    private func rebuildInspiration() async {
        let articles = snapshot.allArticles
        let seasonal = seasonalCollections
        let lowAffinity = RecipeDiscoveryService.lowAffinitySourceIDs(for: discoveryMarketContext)
        let next = await Task.detached(priority: .utility) {
            Self.makeInspiration(articles, lowAffinity: lowAffinity, seasonal: seasonal)
        }.value
        guard !Task.isCancelled else { return }
        inspiration = next
    }

    private func makeDiscoverySeeds() -> [RecipeDiscoveryArticleSeed] {
        let subscribed = feeds.flatMap { feed in
            let sourceID = "feed:\(feed.uuid.uuidString)"
            return feed.sortedItems.map { item in
                RecipeDiscoveryArticleSeed(
                    stableID: item.stableID,
                    title: item.title,
                    articleURL: item.url,
                    imageURL: item.imageURL,
                    author: item.author,
                    summary: item.summary,
                    publishedAt: item.publishedAt,
                    sourceID: sourceID,
                    sourceName: feed.title,
                    date: item.publishedAt ?? item.fetchedAt,
                    isArchived: item.isArchived,
                    providerTags: [],
                    body: nil,
                    mayLookUpImage: item.imageLookupAt == nil,
                    isSubscribed: true
                )
            }
        }
        let publicArticles = discoveredSources.flatMap { result in
            result.articles.enumerated().map { index, article in
                let sourceID = "discovery:\(result.source.id)"
                return RecipeDiscoveryArticleSeed(
                    stableID: article.id,
                    title: article.title,
                    articleURL: article.url,
                    imageURL: article.imageURL,
                    author: article.author,
                    summary: article.summary,
                    publishedAt: article.publishedAt,
                    sourceID: sourceID,
                    sourceName: result.source.name,
                    // Preserve source order for undated public results.
                    date: article.publishedAt ?? Date.distantPast.addingTimeInterval(-Double(index)),
                    isArchived: false,
                    providerTags: article.categories,
                    body: article.body,
                    mayLookUpImage: true,
                    isSubscribed: false
                )
            }
        }
        return subscribed + publicArticles
    }

    private func content(_ article: RecipeDiscoveryArticle) -> RecipeArticleContent {
        RecipeArticleContent(
            id: article.id,
            readStateID: article.readStateID,
            title: article.title,
            articleURL: article.articleURL,
            imageURL: article.imageURL,
            author: article.author,
            summary: article.summary,
            publishedAt: article.publishedAt,
            sourceName: article.sourceName,
            mayLookUpImage: article.mayLookUpImage,
            isRead: article.isRead
        )
    }

    private func markRead(_ article: RecipeArticleContent) {
        RecipeFeedReadState.markRead(article.readStateID)
        snapshot = snapshot.applying(readID: article.readStateID)
        inspiration = inspiration.applying(readID: article.readStateID)
        seasonalReadIDs.insert(article.readStateID)
    }

    /// Writes a picture found on an article's own page back to its stored item,
    /// so the lookup happens once and survives a relaunch.
    private func record(imageURL: URL?, forArticle article: RecipeArticleContent) {
        snapshot = snapshot.applying(imageURL: imageURL, to: article.id)
        guard let feed = feeds.first(where: { feed in
            feed.items?.contains(where: { $0.stableID == article.readStateID }) == true
        }) else { return }
        guard let item = feed.items?.first(where: { $0.stableID == article.readStateID }) else { return }
        if let imageURL { item.imageURLString = imageURL.absoluteString }
        item.imageLookupAt = .now
        snapshotInputRevision &+= 1
        try? context.save()
    }

    /// Seasonal cards use the card's in-memory image result and persist feed
    /// metadata without rebuilding the normal Discover snapshot.
    private func recordSeasonalImage(imageURL: URL?, forArticle article: RecipeArticleContent) {
        guard let feed = feeds.first(where: { feed in
            feed.items?.contains(where: { $0.stableID == article.readStateID }) == true
        }),
        let item = feed.items?.first(where: { $0.stableID == article.readStateID }) else { return }
        if let imageURL { item.imageURLString = imageURL.absoluteString }
        item.imageLookupAt = .now
        try? context.save()
    }

    private func refreshSeasonal() async {
        let context = discoveryMarketContext
        let contextKey = seasonalContextKey
        let refreshRevision = seasonalRefreshRevision
        let now = Date.now
        let moments = SeasonalRecipeCalendar.activeMoments(on: now, context: context)
        let normalSeeds = makeDiscoverySeeds()
        let readIDs = RecipeFeedReadState.readIDs()
        loadingSeasonal = true
        defer {
            if refreshRevision == seasonalRefreshRevision { loadingSeasonal = false }
        }

        var collections: [SeasonalRecipeCollection] = []
        for moment in moments {
            guard !Task.isCancelled else { return }
            let targetedLoad = await SeasonalRecipeCollectionLoader.load(moment: moment, context: context)
            guard !Task.isCancelled else { return }
            let seeds = SeasonalRecipeCollectionLoader.merging(
                normalSeeds: normalSeeds,
                targetedLoad: targetedLoad
            )
            let collection = await Task.detached(priority: .utility) {
                SeasonalRecipeRanking.collection(
                    for: moment,
                    seeds: seeds,
                    context: context,
                    readIDs: readIDs,
                    additionalSources: targetedLoad.sources
                )
            }.value
            if !collection.articles.isEmpty { collections.append(collection) }
        }

        guard !Task.isCancelled else { return }
        seasonalCollections = collections
        seasonalReadIDs = readIDs
        nextSeasonalTransition = SeasonalRecipeCalendar.nextTransition(after: now, context: context)
        completedSeasonalContextKey = contextKey
        completedSeasonalRefreshRevision = refreshRevision
        await rebuildInspiration()
    }

    private func refresh(force: Bool) async {
        if force { refreshing = true }
        async let discoveryLoad = RecipeDiscoveryService.load(context: discoveryMarketContext)
        if !appState.isGuest {
            await RecipeFeedService.refreshAll(context: context, force: force)
        }
        let loaded = await discoveryLoad
        discoveredSources = loaded.sources
        failedDiscoverySources = loaded.failedSourceNames
        // Feed refreshes and public discovery can change article content while
        // keeping the same number of feeds and sources.
        snapshotInputRevision &+= 1
        loadingDiscovery = false
        refreshing = false
        seasonalRefreshRevision &+= 1
    }

    private func open(_ bookmark: RecipeBookmark) {
        guard let url = bookmark.url else { return }
        browserTarget = BookmarkBrowserTarget(title: bookmark.title, url: url)
    }
}

private struct DiscoverySourceOption: Identifiable {
    let id: String
    let name: String
    let siteURL: URL?
}

private struct SubscribedSite: Identifiable {
    let id: UUID
    let name: String
    let url: URL
}

private struct BookmarkBrowserTarget: Identifiable {
    let id = UUID()
    let title: String
    let url: URL
}

/// One explicit online search. Stored in `@State`, and its identity comes
/// from its value, so a redraw never re-presents it.
private struct RecipeWebSearchRequest: Identifiable, Hashable {
    let query: String
    let planningContext: RecipePlanningContext?
    var id: Self { self }
}

extension RecipeInspirationTheme {
    var localizedTitle: String {
        switch self {
        case .quickDinner: String(localized: "Quick dinner")
        case .seasonal: String(localized: "Seasonal ideas")
        case .vegetarian: String(localized: "Vegetarian")
        case .baking: String(localized: "Something to bake")
        }
    }

    /// Why these recipes are here, said plainly: the label is the source's
    /// own, never a promise Meals checked.
    var localizedReason: String {
        switch self {
        case .quickDinner: String(localized: "Their authors call them quick")
        case .seasonal: String(localized: "Right for this time of year")
        case .vegetarian: String(localized: "Marked vegetarian or vegan by the site")
        case .baking: String(localized: "Breads, cakes and bakes")
        }
    }

    var symbolName: String {
        switch self {
        case .quickDinner: "timer"
        case .seasonal: "leaf"
        case .vegetarian: "carrot"
        case .baking: "birthday.cake"
        }
    }
}

/// One "What sounds good today?" choice: a photo from its own recipes behind
/// the name, so the tile shows what it leads to.
@MainActor
private struct InspirationThemeTile: View {
    let choice: DiscoveryInspiration.ThemeChoice
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                Spacer(minLength: 0)
                Image(systemName: choice.theme.symbolName)
                    .font(.title3.weight(.semibold))
                Text(choice.theme.localizedTitle)
                    .font(.headline)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Text(choice.theme.localizedReason)
                    .font(.caption)
                    .opacity(0.9)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(.white)
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 110, alignment: .bottomLeading)
            .background {
                GeometryReader { proxy in
                    RemoteRecipeImage(
                        url: choice.coverImageURL,
                        placeholderSymbol: choice.theme.symbolName,
                        tint: DishGlyph.tint(forName: choice.theme.rawValue),
                        cornerRadius: 18,
                        width: proxy.size.width,
                        height: proxy.size.height
                    )
                    .overlay(
                        LinearGradient(
                            colors: [.black.opacity(0.15), .black.opacity(0.72)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(choice.theme.localizedTitle)
        .accessibilityValue(choice.theme.localizedReason)
        .accessibilityHint(String(localized: "Shows \(choice.articles.count) recipes"))
        .accessibilityAddTraits(.isButton)
    }
}
