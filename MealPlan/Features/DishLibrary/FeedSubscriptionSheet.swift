import SwiftData
import SwiftUI

@MainActor
struct FeedSubscriptionSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var allFeeds: [RecipeFeed]
    @State private var address = ""
    @State private var subscribing = false
    @State private var pendingSuggestion: String?
    @State private var errorMessage: String?
    /// The region whose sites are on offer. Empty means "whatever the device
    /// says", which is what almost everyone leaves it at; a deliberate choice
    /// is remembered, because someone who cooks from French blogs will want
    /// them again next time.
    @AppStorage("RecipeSuggestions.region") private var storedRegion = ""

    private var deviceRegion: RecipeSuggestionRegion { RecipeFeedSuggestions.region() }

    private var region: RecipeSuggestionRegion {
        RecipeSuggestionRegion(rawValue: storedRegion) ?? deviceRegion
    }

    /// Sites already subscribed to drop out of the list, so the section shrinks
    /// as the household works through it instead of offering duplicates.
    private var suggestions: [RecipeFeedSuggestion] {
        let subscribed = Set(allFeeds.flatMap { [$0.siteURL, $0.feedURL] }.compactMap(Self.host))
        return region.sites.filter {
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

                Section {
                    regionPicker
                    ForEach(suggestions) { suggestion in
                        suggestionRow(suggestion)
                    }
                    if suggestions.isEmpty {
                        Text(String(localized: "You’re subscribed to all of these already."))
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text(String(localized: "Suggestions"))
                } footer: {
                    Text(String(localized: "Recipe sites that publish a feed. Tap one to see what it has been cooking."))
                }
            }
            .formStyle(.grouped)
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

    private var regionPicker: some View {
        Picker(
            String(localized: "Region"),
            selection: Binding(
                get: { region },
                set: { storedRegion = $0 == deviceRegion ? "" : $0.rawValue }
            )
        ) {
            ForEach(RecipeSuggestionRegion.ordered(startingWith: deviceRegion)) { option in
                Text(verbatim: "\(option.flag)  \(option.localizedName)").tag(option)
            }
        }
        .pickerStyle(.menu)
    }

    /// Tapping the row looks at what the site has been publishing; the plus is
    /// the shortcut for someone who already knows they want it.
    private func suggestionRow(_ suggestion: RecipeFeedSuggestion) -> some View {
        HStack(alignment: .top, spacing: 12) {
            NavigationLink {
                FeedPreviewView(suggestion: suggestion)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(suggestion.name).font(.headline)
                    Text(suggestion.detail).font(.subheadline).foregroundStyle(.secondary)
                    Text(suggestion.displayHost).font(.caption).foregroundStyle(.tertiary)
                }
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityHint(Text(String(localized: "Shows what this site has published lately")))

            if pendingSuggestion == suggestion.id {
                ProgressView()
            } else {
                Button {
                    Task { await subscribe(to: suggestion) }
                } label: {
                    Image(systemName: "plus.circle")
                        .foregroundStyle(Color.accentColor)
                        .imageScale(.large)
                }
                // Borderless keeps this tappable in a row that is also a link.
                .buttonStyle(.borderless)
                .disabled(subscribing)
                .accessibilityLabel(Text(String(localized: "Subscribe to \(suggestion.name)")))
            }
        }
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
struct RecipeBookmarkSheet: View {
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
            .formStyle(.grouped)
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


/// What a site has been publishing lately, shown before the household commits
/// to subscribing. The articles are the same cards as Discover recipes and open
/// the same reader, so a recipe can be read — and even saved — from a site that
/// is only being considered.
@MainActor
private struct FeedPreviewView: View {
    let suggestion: RecipeFeedSuggestion

    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var resolved: RecipeFeedService.ResolvedFeed?
    @State private var loading = true
    @State private var subscribing = false
    @State private var subscribed = false
    @State private var errorMessage: String?

    private var articles: [RecipeArticleContent] {
        (resolved?.parsed.articles ?? [])
            .filter(RecipeArticleClassifier.isLikelyRecipe)
            .prefix(20)
            .map {
                RecipeArticleContent($0, sourceName: resolved?.parsed.title, sourceID: "preview")
            }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if loading {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                } else if articles.isEmpty {
                    ContentUnavailableView(
                        String(localized: "Nothing to show"),
                        systemImage: "newspaper",
                        description: Text(String(localized: "This site’s feed has no recent posts."))
                    )
                    .padding(.top, 20)
                } else {
                    RecipeArticleGrid(articles: articles) { article in
                        RecipeArticleReaderView(article: article)
                    }
                }
            }
            .padding()
        }
        .navigationTitle(resolved?.parsed.title ?? suggestion.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if subscribing {
                    ProgressView()
                } else {
                    Button(subscribed
                           ? String(localized: "Subscribed")
                           : String(localized: "Subscribe")) {
                        Task { await subscribe() }
                    }
                    .disabled(resolved == nil || subscribed || appState.isGuest)
                }
            }
        }
        .task { await load() }
        .alert(String(localized: "Couldn’t subscribe"), isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) {
            Button(String(localized: "OK"), role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(suggestion.detail).font(.subheadline).foregroundStyle(.secondary)
            if let site = resolved?.parsed.homeURL ?? suggestion.url {
                Link(destination: site) {
                    Label(suggestion.displayHost, systemImage: "safari").font(.caption)
                }
            }
        }
    }

    private func load() async {
        guard resolved == nil, let url = suggestion.url else {
            loading = false
            return
        }
        defer { loading = false }
        do {
            let feed = try await RecipeFeedService.resolveFeed(at: url)
            resolved = feed
            subscribed = RecipeFeedService.isSubscribed(toFeedAt: feed.feedURL, context: context)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Subscribing here reuses the feed already on screen rather than fetching
    /// the site a second time.
    private func subscribe() async {
        guard let resolved else { return }
        subscribing = true
        defer { subscribing = false }
        do {
            try await RecipeFeedService.subscribe(
                to: resolved,
                household: appState.currentHousehold,
                context: context
            )
            subscribed = true
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
