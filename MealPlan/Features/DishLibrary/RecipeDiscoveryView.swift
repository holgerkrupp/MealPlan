import SwiftData
import SwiftUI
import os

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
    @State private var snapshot = RecipeDiscoverySnapshot.empty

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

    private var hasVisibleArticles: Bool { !snapshot.visibleArticles.isEmpty }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20, pinnedViews: [.sectionHeaders]) {
                if loadingDiscovery && snapshot.allArticles.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                } else if snapshot.allArticles.isEmpty && bookmarks.isEmpty && subscribedSites.isEmpty {
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
        .task(id: snapshotTaskID) { await rebuildSnapshot() }
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
            RecipeArticleReaderView(article: article, onImageResolved: { url in
                record(imageURL: url, forArticle: article)
            })
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
                articles: snapshot.visibleArticles.map(content),
                onImageResolved: { article, url in
                    record(imageURL: url, forArticle: article)
                }
            ) { article in
                RecipeArticleReaderView(article: article, onRead: {
                    markRead(article)
                }) { url in
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
                    surpriseArticle = snapshot.visibleArticles.randomElement().map(content)
                }
                .buttonStyle(.borderedProminent)
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
        let feedRevision = feeds.map { feed in
            let itemRevision = (feed.items ?? []).map { item in
                "\(item.stableID):\(item.fetchedAt.timeIntervalSinceReferenceDate):\(item.archivedAt?.timeIntervalSinceReferenceDate ?? 0)"
            }.joined(separator: ",")
            return "\(feed.uuid.uuidString):\(itemRevision)"
        }.joined(separator: "|")
        let publicRevision = discoveredSources.map { result in
            "\(result.source.id):\(result.articles.map { $0.id }.joined(separator: ","))"
        }.joined(separator: "|")
        return "\(search)|\(scope.rawValue)|\(sort.rawValue)|\(sourceFilter ?? "*")|\(selectedCategory?.rawValue ?? "*")|\(feedRevision)|\(publicRevision)"
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
        let sourceOrder = sourceOptions.map(\.id)
        let query = discoveryQuery
        let readIDs = RecipeFeedReadState.readIDs()
        let next = await Task.detached(priority: .userInitiated) {
            RecipeDiscoverySnapshot.build(
                seeds: seeds,
                sourceOrder: sourceOrder,
                query: query,
                readIDs: readIDs
            )
        }.value
        guard !Task.isCancelled else { return }
        snapshot = next
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
        snapshot = snapshot.applying(readIDs: RecipeFeedReadState.readIDs())
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

private struct BookmarkBrowserTarget: Identifiable {
    let id = UUID()
    let dish: Dish
    let url: URL
}
