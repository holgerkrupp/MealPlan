import Foundation

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

    private let concurrencyLimit = 3
    private var running = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func lookUpImage(forArticleAt url: URL) async -> ArticleImageLookup {
        await acquireSlot()
        defer { releaseSlot() }

        guard let html = try? await RecipeArticleCache.shared.articleHTML(for: url) else {
            return .unreachable
        }
        if let image = Self.imageURL(inHTML: html, relativeTo: url) {
            return .found(image)
        }
        return .none
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

    private func acquireSlot() async {
        if running < concurrencyLimit {
            running += 1
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    /// Hands the slot straight to whoever is next rather than decrementing, so
    /// the count never dips below the work actually in flight.
    private func releaseSlot() {
        if waiting.isEmpty {
            running -= 1
        } else {
            waiting.removeFirst().resume()
        }
    }
}
