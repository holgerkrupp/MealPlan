import Foundation
import os

/// What a trip to an article's own page turned up.
enum ArticleImageLookup: Sendable, Equatable {
    case found(URL)
    /// The page was read and simply advertises no usable picture. Worth
    /// remembering, so the card never asks again.
    case none
    /// The page could not be read at all. Deliberately *not* remembered — a
    /// flaky connection should not cost an article its photo for good.
    case unreachable
}

/// Finds a picture for a feed article whose feed didn't provide one.
///
/// Plenty of feeds carry nothing but a title, a link and a paragraph of text,
/// which used to leave a wall of identical newspaper placeholders. The article's
/// own page nearly always has a photo — the social-preview image if nothing
/// else — so the card goes and looks.
///
/// Fetching a whole HTML page per card is not free, so this is deliberately
/// lazy (only cards that get drawn ask), throttled (a screenful of cards does
/// not open twenty connections), and recorded on the item so it happens once in
/// an article's life. The pages land in `RecipeArticleCache`, which means
/// opening the article afterwards is instant.
actor RecipeFeedImageResolver {
    static let shared = RecipeFeedImageResolver()

    typealias Loader = @Sendable (URL) async -> ArticleImageLookup

    private let concurrencyLimit: Int
    private let loader: Loader
    private var running = 0
    private var waiting: [UUID: CheckedContinuation<Bool, Never>] = [:]
    private var cached: [URL: ArticleImageLookup] = [:]
    private var inFlight: [URL: Task<ArticleImageLookup, Never>] = [:]

    init(concurrencyLimit: Int = 3, loader: Loader? = nil) {
        self.concurrencyLimit = max(1, concurrencyLimit)
        self.loader = loader ?? { url in
            guard let html = try? await RecipeArticleCache.shared.articleHTML(for: url) else {
                return .unreachable
            }
            if let image = Self.imageURL(inHTML: html, relativeTo: url) {
                return .found(image)
            }
            return .none
        }
    }

    func lookUpImage(forArticleAt url: URL) async -> ArticleImageLookup {
        if let cachedResult = cached[url] { return cachedResult }
        if let existing = inFlight[url] {
            let result = await existing.value
            return Task.isCancelled ? .unreachable : result
        }

        let task = Task { [loader] in
            guard await self.acquireSlot() else { return ArticleImageLookup.unreachable }
            defer { Task { await self.releaseSlot() } }
            guard !Task.isCancelled else { return .unreachable }
            let state = RecipePerformanceSignposts.signposter.beginInterval("article image lookup")
            let result = await loader(url)
            RecipePerformanceSignposts.signposter.endInterval("article image lookup", state)
            return result
        }
        inFlight[url] = task
        let result = await task.value
        inFlight[url] = nil
        if result != .unreachable { cached[url] = result }
        return Task.isCancelled ? .unreachable : result
    }

    /// The best picture a recipe page advertises. A `schema.org` recipe's own
    /// image beats the social-preview one, which is sometimes the site's logo.
    nonisolated static func imageURL(inHTML html: String, relativeTo base: URL) -> URL? {
        var candidates: [String] = []
        if let recipe = RecipeSchemaParser().parseJSONLD(html: html, sourceURL: base),
           let fromRecipe = recipe.imageURLString {
            candidates.append(fromRecipe)
        }
        candidates.append(contentsOf: RecipeSchemaParser.pageImageURLs(in: html))

        for candidate in candidates {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let url = URL(string: trimmed, relativeTo: base)?.absoluteURL,
                  url.scheme?.lowercased().hasPrefix("http") == true else { continue }
            return url
        }
        return nil
    }

    // MARK: - Throttle

    private func acquireSlot() async -> Bool {
        guard !Task.isCancelled else { return false }
        if running < concurrencyLimit {
            running += 1
            return true
        }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiting[id] = continuation
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    /// Hands the slot straight to whoever is next rather than decrementing, so
    /// the count never dips below the work actually in flight.
    private func releaseSlot() {
        if waiting.isEmpty {
            running -= 1
        } else {
            let id = waiting.keys.first!
            waiting.removeValue(forKey: id)?.resume(returning: true)
        }
    }

    private func cancelWaiter(_ id: UUID) {
        waiting.removeValue(forKey: id)?.resume(returning: false)
    }
}
