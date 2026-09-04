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

    private var feeds: [RecipeFeed] {
        allFeeds.filter { $0.household?.uuid == appState.currentHousehold?.uuid }
    }

    private var bookmarks: [RecipeBookmark] {
        allBookmarks.filter { $0.household?.uuid == appState.currentHousehold?.uuid }
    }

    var body: some View {
        List {
            if feeds.isEmpty && bookmarks.isEmpty { discoveryEmptyState }
            ForEach(feeds) { feed in
                Section {
                    if feed.sortedItems.isEmpty {
                        Text(String(localized: "No posts yet."))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(feed.sortedItems.prefix(20)) { item in
                            NavigationLink {
                                RecipeArticleReaderView(item: item)
                            } label: {
                                articleRow(item)
                            }
                        }
                    }
                } header: {
                    feedHeader(feed)
                } footer: {
                    feedFooter(feed)
                }
            }

            if !bookmarks.isEmpty {
                Section(String(localized: "Recipe sites")) {
                    ForEach(bookmarks) { bookmark in
                        Button {
                            open(bookmark)
                        } label: {
                            Label(bookmark.title, systemImage: "bookmark")
                        }
                        .swipeActions {
                            if !appState.isGuest {
                                Button(String(localized: "Delete"), role: .destructive) {
                                    context.delete(bookmark)
                                    try? context.save()
                                }
                            }
                        }
                    }
                }
            }
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
        .listRowBackground(Color.clear)
    }

    private func articleRow(_ item: RecipeFeedItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(RecipeFeedReadState.isRead(item.stableID) ? Color.clear : Color.accentColor)
                .frame(width: 7, height: 7)
                .padding(.top, 7)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title).font(.headline)
                if let summary = item.summary {
                    Text(summary).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                }
                if let date = item.publishedAt {
                    Text(date, format: .dateTime.day().month().year())
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func feedHeader(_ feed: RecipeFeed) -> some View {
        HStack {
            Text(feed.title)
            Spacer()
            if let site = feed.siteURL {
                Link(destination: site) { Image(systemName: "safari") }
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
            }
        }
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

@MainActor
private struct RecipeArticleReaderView: View {
    let item: RecipeFeedItem

    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var context
    @State private var articleText: String?
    @State private var html: String?
    @State private var loading = true
    @State private var saving = false
    @State private var saved = false
    @State private var noRecipeFound = false
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(item.title).font(.largeTitle.bold())
                if let author = item.author { Text(author).foregroundStyle(.secondary) }
                if loading { ProgressView() }
                if let articleText {
                    Text(articleText)
                        .font(.body)
                        .lineSpacing(5)
                        .textSelection(.enabled)
                } else if let summary = item.summary {
                    Text(summary).font(.body).lineSpacing(5)
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
                Button {
                    Task { await saveRecipe() }
                } label: {
                    if saving { ProgressView() }
                    else if saved { Label(String(localized: "Saved"), systemImage: "checkmark.circle") }
                    else if noRecipeFound { Label(String(localized: "No recipe found"), systemImage: "xmark.circle") }
                    else { Label(String(localized: "Save recipe"), systemImage: "square.and.arrow.down") }
                }
                .disabled(loading || saving || saved || noRecipeFound || html == nil || appState.isGuest)
            }
        }
        .task { await load() }
        .alert(String(localized: "Couldn’t read that page"), isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) {
            Button(String(localized: "OK"), role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
    }

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
        } catch {
            errorMessage = error.localizedDescription
        }
        loading = false
    }

    private func saveRecipe() async {
        guard let html, let url = item.url else { return }
        saving = true
        defer { saving = false }
        do {
            let recipe = try await RecipeSchemaParser().importRecipe(fromHTML: html, sourceURL: url)
            guard !recipe.ingredientLines.isEmpty || !(recipe.instructions ?? "").isEmpty else {
                noRecipeFound = true
                return
            }
            let result = RecipeImportCommitter.importAll(
                [recipe],
                household: appState.currentHousehold,
                createdByName: appState.currentMemberName,
                context: context
            )
            saved = true
            appState.importNotice = result.summary
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

@MainActor
private struct FeedSubscriptionSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var subscribing = false
    @State private var errorMessage: String?

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
            }
            .navigationTitle(String(localized: "Subscribe to a site"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Subscribe")) { Task { await subscribe() } }
                        .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty || subscribing)
                }
            }
            .alert(String(localized: "Couldn’t subscribe"), isPresented: Binding(
                get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
            )) {
                Button(String(localized: "OK"), role: .cancel) {}
            } message: { Text(errorMessage ?? "") }
        }
        .presentationDetents([.medium])
    }

    private func subscribe() async {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed.contains("://") ? trimmed : "https://\(trimmed)") else {
            errorMessage = RecipeFeedParserError.invalidURL.localizedDescription
            return
        }
        subscribing = true
        defer { subscribing = false }
        do {
            _ = try await RecipeFeedService.subscribe(to: url, household: appState.currentHousehold, context: context)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
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
