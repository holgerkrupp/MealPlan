import Foundation

enum SeasonalMatchSignal: String, CaseIterable, Hashable, Sendable {
    case title
    case summary
    case providerTag
    case body
}

struct SeasonalRecipeMatch: Identifiable, Hashable, Sendable {
    let articleID: String
    let momentID: String
    let score: Int
    let matchedSignals: [SeasonalMatchSignal]
    let matchedKeywords: [String]

    var id: String { "\(momentID):\(articleID)" }
}

struct SeasonalRecipeRankedCandidate: Sendable {
    let seed: RecipeDiscoveryArticleSeed
    let match: SeasonalRecipeMatch
    let marketPriority: Int
}

struct SeasonalRecipeCollection: Identifiable, Sendable {
    let moment: SeasonalRecipeMoment
    let articles: [RecipeDiscoveryArticle]

    var id: String { moment.id }
}

enum SeasonalRecipeRanking {
    static let defaultLimit = 8
    static let maximumLimit = 12
    static let defaultPerSourceLimit = 2
    static let strongMatchThreshold = 24

    /// Ranks only the value metadata already present in the discovery stream.
    /// It never fetches or parses article pages.
    static func rank(
        seeds: [RecipeDiscoveryArticleSeed],
        for moment: SeasonalRecipeMoment,
        context: RecipeDiscoveryMarketContext,
        additionalSources: [RecipeDiscoverySource] = [],
        limit: Int = defaultLimit,
        perSourceLimit: Int = defaultPerSourceLimit
    ) -> [SeasonalRecipeRankedCandidate] {
        let boundedLimit = min(max(limit, 0), maximumLimit)
        guard boundedLimit > 0 else { return [] }

        let sourceMetadata = Dictionary(
            (RecipeDiscoveryService.sources + additionalSources).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let candidates = SeasonalRecipeURL.unique(seeds).compactMap { seed -> SeasonalRecipeRankedCandidate? in
            guard seed.isSubscribed || RecipeArticleClassifier.isLikelyRecipe(
                title: seed.title,
                summary: seed.summary,
                url: seed.articleURL,
                providerTags: seed.providerTags,
                body: seed.body
            ) else { return nil }
            guard let match = score(seed, for: moment, context: context, sourceMetadata: sourceMetadata) else {
                return nil
            }
            return SeasonalRecipeRankedCandidate(
                seed: seed,
                match: match,
                marketPriority: affinity(for: seed.sourceID, context: context, sourceMetadata: sourceMetadata)
            )
        }

        let sourceLimit = max(perSourceLimit, 1)
        let foreignLimit = max(1, (boundedLimit + 3) / 4)
        var result: [SeasonalRecipeRankedCandidate] = []
        var sourceCounts: [String: Int] = [:]
        var foreignCount = 0

        // Strong matches across all market tiers precede weak matches. Within
        // each tier, round-robin by source prevents a prolific provider from
        // taking the whole shelf.
        for isStrong in [true, false] {
            for priority in 0...2 where result.count < boundedLimit {
                let tier = candidates.filter {
                    ($0.match.score >= strongMatchThreshold) == isStrong
                        && $0.marketPriority == priority
                        && (sourceCounts[$0.seed.sourceID] ?? 0) < sourceLimit
                }
                for candidate in interleaveBySource(tier) {
                    guard result.count < boundedLimit else { break }
                    guard (sourceCounts[candidate.seed.sourceID] ?? 0) < sourceLimit else { continue }
                    if candidate.marketPriority == 2, foreignCount >= foreignLimit { continue }
                    result.append(candidate)
                    sourceCounts[candidate.seed.sourceID, default: 0] += 1
                    if candidate.marketPriority == 2 { foreignCount += 1 }
                }
            }
        }
        return result
    }

    static func collection(
        for moment: SeasonalRecipeMoment,
        seeds: [RecipeDiscoveryArticleSeed],
        context: RecipeDiscoveryMarketContext,
        readIDs: Set<String>,
        additionalSources: [RecipeDiscoverySource] = [],
        limit: Int = defaultLimit,
        perSourceLimit: Int = defaultPerSourceLimit
    ) -> SeasonalRecipeCollection {
        let ranked = rank(
            seeds: seeds,
            for: moment,
            context: context,
            additionalSources: additionalSources,
            limit: limit,
            perSourceLimit: perSourceLimit
        )
        let articles = ranked.map { candidate in
            let seed = candidate.seed
            return RecipeDiscoveryArticle(
                id: seed.id,
                readStateID: seed.readStateID,
                title: seed.title,
                articleURL: seed.articleURL,
                imageURL: seed.imageURL,
                author: seed.author,
                summary: seed.summary,
                publishedAt: seed.publishedAt,
                sourceID: seed.sourceID,
                sourceName: seed.sourceName,
                date: seed.date,
                isArchived: seed.isArchived,
                categories: RecipeDiscoveryCategory.categories(
                    title: seed.title,
                    summary: seed.summary,
                    providerTags: seed.providerTags
                ),
                mayLookUpImage: seed.mayLookUpImage,
                isRead: readIDs.contains(seed.readStateID)
            )
        }
        return SeasonalRecipeCollection(moment: moment, articles: articles)
    }

    private static func score(
        _ seed: RecipeDiscoveryArticleSeed,
        for moment: SeasonalRecipeMoment,
        context: RecipeDiscoveryMarketContext,
        sourceMetadata: [String: RecipeDiscoverySource]
    ) -> SeasonalRecipeMatch? {
        let languageCodes = relevantLanguages(
            for: seed.sourceID,
            moment: moment,
            context: context,
            sourceMetadata: sourceMetadata
        )
        let keywords = uniqueKeywords(moment: moment, languages: languageCodes)
        guard !keywords.isEmpty else { return nil }

        let title = normalized(seed.title)
        let summary = normalized(seed.summary ?? "")
        let providerTags = normalized(seed.providerTags.joined(separator: " "))
        let body = normalized(seed.body ?? "")
        var score = 0
        var signals = Set<SeasonalMatchSignal>()
        var matched = Set<String>()

        for keyword in keywords {
            let key = normalized(keyword)
            guard !key.isEmpty else { continue }
            if contains(key, in: title) {
                score += 32
                signals.insert(.title)
                matched.insert(keyword)
            }
            if contains(key, in: providerTags) {
                score += 30
                signals.insert(.providerTag)
                matched.insert(keyword)
            }
            if contains(key, in: summary) {
                score += 14
                signals.insert(.summary)
                matched.insert(keyword)
            }
            if contains(key, in: body) {
                score += 5
                signals.insert(.body)
                matched.insert(keyword)
            }
        }

        guard score > 0 else { return nil }
        return SeasonalRecipeMatch(
            articleID: seed.id,
            momentID: moment.id,
            score: min(score, 100),
            matchedSignals: SeasonalMatchSignal.allCases.filter { signals.contains($0) },
            matchedKeywords: matched.sorted()
        )
    }

    private static func relevantLanguages(
        for sourceID: String,
        moment: SeasonalRecipeMoment,
        context: RecipeDiscoveryMarketContext,
        sourceMetadata: [String: RecipeDiscoverySource]
    ) -> [String] {
        var languages: [String] = []
        if sourceID.hasPrefix("discovery:") {
            let key = String(sourceID.dropFirst("discovery:".count))
            if let source = sourceMetadata[key] {
                languages.append(contentsOf: source.languageCodes.sorted())
                if source.marketScope == .international { languages.append("en") }
            }
        } else if sourceID.hasPrefix("feed:") {
            // A subscribed feed has no declared language metadata. It is
            // explicitly user-chosen, so allow the localized keyword groups
            // already present in the catalog rather than guessing from its URL.
            languages.append(contentsOf: moment.localizedKeywords.keys.sorted())
        }
        if let languageCode = context.languageCode { languages.append(languageCode) }
        if languages.isEmpty { languages.append("en") }
        var seen = Set<String>()
        return languages.map { $0.lowercased() }.filter { seen.insert($0).inserted }
    }

    private static func uniqueKeywords(moment: SeasonalRecipeMoment, languages: [String]) -> [String] {
        var seen = Set<String>()
        return languages.flatMap { moment.keywords(for: $0) }.filter { keyword in
            seen.insert(normalized(keyword)).inserted
        }
    }

    private static func affinity(
        for sourceID: String,
        context: RecipeDiscoveryMarketContext,
        sourceMetadata: [String: RecipeDiscoverySource]
    ) -> Int {
        if sourceID.hasPrefix("feed:") { return 0 }
        guard sourceID.hasPrefix("discovery:") else { return 2 }
        let key = String(sourceID.dropFirst("discovery:".count))
        guard let source = sourceMetadata[key] else { return 2 }
        if let builtIn = RecipeDiscoveryService.sources.first(where: { $0.id == source.id }) {
            return RecipeDiscoveryService.marketPriority(of: builtIn, for: context)
        }

        if source.marketScope == .international { return 1 }
        let regionalSources = sourceMetadata.values.filter { $0.marketScope == .regional }
        let regionHasMatch = context.regionCode.map { region in
            regionalSources.contains { $0.preferredRegionCodes.contains(region) }
        } ?? false
        if regionHasMatch, let regionCode = context.regionCode,
           source.preferredRegionCodes.contains(regionCode) { return 0 }
        if !regionHasMatch, let languageCode = context.languageCode,
           source.languageCodes.contains(languageCode) { return 0 }
        return 2
    }

    private static func interleaveBySource(
        _ candidates: [SeasonalRecipeRankedCandidate]
    ) -> [SeasonalRecipeRankedCandidate] {
        let groups = Dictionary(grouping: candidates, by: { $0.seed.sourceID })
        let sourceIDs = groups.keys.sorted()
        let sortedGroups = sourceIDs.map { sourceID in
            (groups[sourceID] ?? []).sorted {
                if $0.match.score != $1.match.score { return $0.match.score > $1.match.score }
                return $0.seed.id < $1.seed.id
            }
        }
        guard let longest = sortedGroups.map(\.count).max() else { return [] }
        return (0..<longest).flatMap { index in
            sortedGroups.compactMap { index < $0.count ? $0[index] : nil }
        }
    }

    private static func normalized(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        .replacingOccurrences(of: #"[^\p{L}\p{N}]+"#, with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func contains(_ keyword: String, in text: String) -> Bool {
        guard !text.isEmpty else { return false }
        if (" \(text) ").contains(" \(keyword) ") { return true }
        // German recipe titles often join the seasonal ingredient with the
        // dish name (for example, "Kürbissuppe"). A modest prefix rule covers
        // those compounds without treating short words such as "fall" as a
        // match inside unrelated words.
        guard keyword.count >= 5 else { return false }
        return text.split(separator: " ").contains { $0.hasPrefix(keyword) }
    }
}

enum SeasonalRecipeURL {
    static func canonicalURLKey(_ url: URL) -> String {
        let canonical = RecipeSiteDiscoveryService.canonicalize(url)
        guard var components = URLComponents(url: canonical, resolvingAgainstBaseURL: true) else {
            return canonical.absoluteString
        }
        components.fragment = nil
        if let queryItems = components.queryItems {
            components.queryItems = queryItems.filter { item in
                let name = item.name.lowercased()
                return !name.hasPrefix("utm_") && name != "fbclid" && name != "gclid"
            }.sorted {
                if $0.name != $1.name { return $0.name < $1.name }
                return ($0.value ?? "") < ($1.value ?? "")
            }
        }
        return components.url?.absoluteString ?? canonical.absoluteString
    }

    /// Keeps the normal Discover seed when a targeted seasonal collection
    /// repeats its URL, then appends only new canonical recipe URLs.
    static func appendingUnique(
        existing: [RecipeDiscoveryArticleSeed],
        targeted: [RecipeDiscoveryArticleSeed]
    ) -> [RecipeDiscoveryArticleSeed] {
        unique(existing + targeted)
    }

    static func unique(_ seeds: [RecipeDiscoveryArticleSeed]) -> [RecipeDiscoveryArticleSeed] {
        var seenURLs = Set<String>()
        var seenIDs = Set<String>()
        return seeds.filter { seed in
            guard let url = seed.articleURL else { return seenIDs.insert(seed.id).inserted }
            return seenURLs.insert(canonicalURLKey(url)).inserted
        }
    }
}
