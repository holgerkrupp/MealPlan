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
    @State private var search = ""
    @State private var sort: RecipeArticleSort = .newest
    @State private var scope: RecipeArticleScope = .current
    /// nil means every subscribed site.
    @State private var feedFilter: UUID?

    private var feeds: [RecipeFeed] {
        allFeeds.filter { $0.household?.uuid == appState.currentHousehold?.uuid }
    }

    private var bookmarks: [RecipeBookmark] {
        allBookmarks.filter { $0.household?.uuid == appState.currentHousehold?.uuid }
    }

    private var visibleFeeds: [RecipeFeed] {
        feeds.filter { feedFilter == nil || $0.uuid == feedFilter }
    }

    /// True while the view is showing less than everything it has, which is
    /// what the empty state and the toolbar badge key off.
    private var isFiltering: Bool {
        !search.trimmingCharacters(in: .whitespaces).isEmpty
            || scope != .current
            || feedFilter != nil
    }

    private var hasVisibleArticles: Bool {
        visibleFeeds.contains { !articles(of: $0).isEmpty }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20, pinnedViews: [.sectionHeaders]) {
                if feeds.isEmpty && bookmarks.isEmpty {
                    discoveryEmptyState
                } else if isFiltering && !hasVisibleArticles {
                    noMatchesEmptyState
                }
                ForEach(visibleFeeds) { feed in
                    // While filtering, a site with no matches is left out
                    // rather than shown as an empty heading.
                    if !isFiltering || !articles(of: feed).isEmpty {
                        Section {
                            feedBody(feed)
                        } header: {
                            feedHeader(feed)
                        }
                    }
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
            if articles(of: feed).isEmpty {
                Text(isFiltering
                     ? String(localized: "Nothing here matches.")
                     : String(localized: "No posts yet."))
                    .foregroundStyle(.secondary)
            } else {
                RecipeArticleGrid(
                    articles: articles(of: feed),
                    onImageResolved: { article, url in
                        record(imageURL: url, forArticle: article, in: feed)
                    }
                ) { article in
                    RecipeArticleReaderView(article: article) { url in
                        record(imageURL: url, forArticle: article, in: feed)
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
            if feeds.count > 1 {
                Picker(String(localized: "Site"), selection: $feedFilter) {
                    Text(String(localized: "All sites")).tag(UUID?.none)
                    ForEach(feeds) { feed in
                        Text(feed.title).tag(UUID?.some(feed.uuid))
                    }
                }
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
                feedFilter = nil
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    /// The articles of one feed, after the search field, the scope and the sort
    /// have had their say. Capped while simply browsing, uncapped once the
    /// household is actually looking for something.
    private func articles(of feed: RecipeFeed) -> [RecipeArticleContent] {
        let matching = feed.sortedItems.filter { item in
            RecipeArticleFilter.matches(
                candidate(item, feedTitle: feed.title),
                scope: scope,
                search: search
            )
        }
        let sorted = matching.sorted {
            RecipeArticleFilter.areInOrder(
                candidate($0, feedTitle: feed.title),
                candidate($1, feedTitle: feed.title),
                sort: sort
            )
        }
        let limit = isFiltering ? 60 : 20
        return sorted.prefix(limit).map(RecipeArticleContent.init)
    }

    private func candidate(_ item: RecipeFeedItem, feedTitle: String) -> RecipeArticleFilter.Candidate {
        RecipeArticleFilter.Candidate(
            title: item.title,
            summary: item.summary,
            author: item.author,
            feedTitle: feedTitle,
            date: item.publishedAt ?? item.fetchedAt,
            isArchived: item.isArchived,
            isRead: RecipeFeedReadState.isRead(item.stableID)
        )
    }

    /// Writes a picture found on an article's own page back to its stored item,
    /// so the lookup happens once and survives a relaunch.
    private func record(imageURL: URL?, forArticle article: RecipeArticleContent, in feed: RecipeFeed) {
        guard let item = feed.items?.first(where: { $0.stableID == article.id }) else { return }
        if let imageURL { item.imageURLString = imageURL.absoluteString }
        item.imageLookupAt = .now
        try? context.save()
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
