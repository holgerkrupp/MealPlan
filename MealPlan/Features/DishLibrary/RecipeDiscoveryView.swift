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
    @State private var loadingDiscovery = true
    @State private var discoveredSources: [RecipeDiscoverySourceResult] = []
    @State private var failedDiscoverySources: [String] = []
    @State private var selectedCategory: RecipeDiscoveryCategory?
    @State private var surpriseArticle: RecipeArticleContent?
    @State private var search = ""
    @State private var sort: RecipeArticleSort = .mixed
    @State private var scope: RecipeArticleScope = .current
    /// nil means built-in and subscribed sources together.
    @State private var sourceFilter: String?

    private var feeds: [RecipeFeed] {
        allFeeds.filter { $0.household?.uuid == appState.currentHousehold?.uuid }
    }

    private var bookmarks: [RecipeBookmark] {
        allBookmarks.filter { $0.household?.uuid == appState.currentHousehold?.uuid }
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

    /// True while the view is showing less than everything it has, which is
    /// what the empty state and the toolbar badge key off.
    private var isFiltering: Bool {
        !search.trimmingCharacters(in: .whitespaces).isEmpty
            || scope != .current
            || sourceFilter != nil
            || selectedCategory != nil
    }

    private var hasVisibleArticles: Bool {
        !visibleArticles.isEmpty
    }

    private var allArticles: [DiscoveryArticle] {
        let subscribed = feeds.flatMap { feed in
            feed.sortedItems.filter { item in
                RecipeArticleClassifier.isLikelyRecipe(
                    title: item.title,
                    summary: item.summary,
                    url: item.url
                )
            }.map { item in
                let sourceID = "feed:\(feed.uuid.uuidString)"
                return DiscoveryArticle(
                    content: RecipeArticleContent(item, sourceName: feed.title, sourceID: sourceID),
                    sourceID: sourceID,
                    sourceName: feed.title,
                    date: item.publishedAt ?? item.fetchedAt,
                    isArchived: item.isArchived,
                    categories: RecipeDiscoveryCategory.categories(
                        title: item.title,
                        summary: item.summary,
                        providerTags: []
                    ),
                    feed: feed
                )
            }
        }
        let publicArticles = discoveredSources.flatMap { result in
            result.articles.enumerated().map { index, article in
                let sourceID = "discovery:\(result.source.id)"
                return DiscoveryArticle(
                    content: RecipeArticleContent(
                        article,
                        sourceName: result.source.name,
                        sourceID: sourceID
                    ),
                    sourceID: sourceID,
                    sourceName: result.source.name,
                    // Card order is meaningful on sources without dates. Keep
                    // that order while still placing them after dated posts in
                    // the explicit newest/oldest modes.
                    date: article.publishedAt ?? Date.distantPast.addingTimeInterval(-Double(index)),
                    isArchived: false,
                    categories: RecipeDiscoveryCategory.categories(
                        title: article.title,
                        summary: article.summary,
                        providerTags: article.categories
                    ),
                    feed: nil
                )
            }
        }
        // Prefer the stored copy when a household has subscribed to one of the
        // built-in sources, so image backfills still persist and the same URL
        // does not appear twice in the mixed grid.
        return subscribed + publicArticles
    }

    private var categoryCandidates: [DiscoveryArticle] {
        var seenURLs: Set<String> = []
        return allArticles.filter { article in
            (sourceFilter == nil || article.sourceID == sourceFilter)
                && RecipeArticleFilter.matches(
                    candidate(article),
                    scope: scope,
                    search: search
                )
                && seenURLs.insert(article.content.articleURL?.absoluteString ?? article.id).inserted
        }
    }

    private var availableCategories: [RecipeDiscoveryCategory] {
        RecipeDiscoveryCategory.allCases.filter { category in
            categoryCandidates.contains { $0.categories.contains(category) }
        }
    }

    private var visibleArticles: [DiscoveryArticle] {
        let matching = categoryCandidates.filter { article in
            guard let selectedCategory else { return true }
            return article.categories.contains(selectedCategory)
        }

        if sort == .mixed {
            let groups = sourceOptions.map { option in
                matching.filter { $0.sourceID == option.id }.sorted {
                    RecipeArticleFilter.areInOrder(candidate($0), candidate($1), sort: .newest)
                }
            }
            return Array(RecipeArticleFilter.interleave(groups).prefix(isFiltering ? 80 : 40))
        }

        return Array(matching.sorted {
            RecipeArticleFilter.areInOrder(candidate($0), candidate($1), sort: sort)
        }.prefix(isFiltering ? 80 : 40))
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20, pinnedViews: [.sectionHeaders]) {
                if loadingDiscovery && allArticles.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                } else if allArticles.isEmpty && bookmarks.isEmpty && subscribedSites.isEmpty {
                    discoveryEmptyState
                } else if isFiltering && !hasVisibleArticles {
                    noMatchesEmptyState
                }
                if !subscribedSites.isEmpty {
                    subscribedSitesSection
                }
                if hasVisibleArticles {
                    articleSection
                }
                if !bookmarks.isEmpty && !isFiltering { bookmarksSection }
            }
            .padding(.vertical)
        }
        .navigationTitle(String(localized: "Discover recipes"))
        .refreshable { await refresh(force: true) }
        .searchable(
            text: $search,
            prompt: Text(String(localized: "Search recipes and sites"))
        )
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
        .detailPresentation(isPresented: $showingSubscription, route: .subscribeToSite) {
            FeedSubscriptionSheet()
        }
        .detailPresentation(isPresented: $showingBookmark, route: .addRecipeSite) {
            RecipeBookmarkSheet()
        }
        .detailPresentation(
            item: $browserTarget,
            route: { .browseSite(url: $0.url, title: $0.dish.name) }
        ) { target in
            NavigationStack {
                RecipeFinderView(dish: target.dish, initialURL: target.url, createsDish: true)
            }
            .dismissesOnOutsideClick()
        }
        .navigationDestination(item: $surpriseArticle) { article in
            RecipeArticleReaderView(article: article) { url in
                record(imageURL: url, forArticle: article)
            }
        }
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

    private var subscribedSitesSection: some View {
        Section {
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
        } header: {
            Text(String(localized: "Subscribed sites"))
                .font(.title3.weight(.semibold))
                .padding(.horizontal, MacLayout.gutter)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var articleSection: some View {
        Section {
            categoryBrowser
                .padding(.horizontal, MacLayout.gutter)

            RecipeArticleGrid(
                articles: visibleArticles.map(\.content),
                onImageResolved: { article, url in
                    record(imageURL: url, forArticle: article)
                }
            ) { article in
                RecipeArticleReaderView(article: article) { url in
                    record(imageURL: url, forArticle: article)
                }
            }
            .padding(.horizontal, MacLayout.gutter)

            discoveryStatus
                .padding(.horizontal, MacLayout.gutter)
        } header: {
            HStack {
                Text(sourceFilter.flatMap { selected in
                    sourceOptions.first(where: { $0.id == selected })?.name
                } ?? String(localized: "Recipes from across the web"))
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
                    surpriseArticle = visibleArticles.randomElement()?.content
                }
                .buttonStyle(.borderedProminent)
                .disabled(visibleArticles.isEmpty)
            }

            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    categoryButton(nil, title: String(localized: "All recipes"), symbol: "square.grid.2x2")
                    ForEach(availableCategories) { category in
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

    private func candidate(_ article: DiscoveryArticle) -> RecipeArticleFilter.Candidate {
        RecipeArticleFilter.Candidate(
            title: article.content.title,
            summary: article.content.summary,
            author: article.content.author,
            feedTitle: article.sourceName,
            date: article.date,
            isArchived: article.isArchived,
            isRead: RecipeFeedReadState.isRead(article.content.readStateID)
        )
    }

    /// Writes a picture found on an article's own page back to its stored item,
    /// so the lookup happens once and survives a relaunch.
    private func record(imageURL: URL?, forArticle article: RecipeArticleContent) {
        guard let feed = allArticles.first(where: { $0.id == article.id })?.feed else { return }
        guard let item = feed.items?.first(where: { $0.stableID == article.readStateID }) else { return }
        if let imageURL { item.imageURLString = imageURL.absoluteString }
        item.imageLookupAt = .now
        try? context.save()
    }

    private func refresh(force: Bool) async {
        if force { refreshing = true }
        async let discoveryLoad = RecipeDiscoveryService.load()
        if !appState.isGuest {
            await RecipeFeedService.refreshAll(context: context, force: force)
        }
        let loaded = await discoveryLoad
        discoveredSources = loaded.sources
        failedDiscoverySources = loaded.failedSourceNames
        loadingDiscovery = false
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

private struct DiscoveryArticle: Identifiable {
    var id: String { content.id }
    let content: RecipeArticleContent
    let sourceID: String
    let sourceName: String
    let date: Date
    let isArchived: Bool
    let categories: Set<RecipeDiscoveryCategory>
    let feed: RecipeFeed?
}

private struct BookmarkBrowserTarget: Identifiable {
    let id = UUID()
    let dish: Dish
    let url: URL
}
