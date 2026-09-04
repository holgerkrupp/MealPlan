import Foundation

/// Pulls a concrete recipe out of a social-media link — YouTube, Instagram,
/// TikTok, Pinterest, Facebook — rather than just saving the URL.
///
/// None of these sites publish `schema.org/Recipe` markup, so there is nothing
/// for `RecipeSchemaParser` to read. What they *do* expose, without an API key
/// or a login, is text: a video description, a post caption, and — for YouTube —
/// the caption/subtitle track, which is the whole method spoken aloud. This type
/// harvests whatever of that it can reach and hands the blob to
/// `RecipeExtractor` (the on-device Apple Intelligence model) to separate the
/// name, ingredients and steps. Everything the model can't be run on falls back
/// to keeping the caption as the instructions text — still better than a bare
/// link.
///
/// `RecipeSchemaParser.importRecipe(from:)` delegates here automatically for a
/// recognised host, so every existing entry point (share extension, paste-a-link,
/// the App Intent, the in-app recipe finder) gets it for free.
struct SocialRecipeImporter: Sendable {

    var session: URLSession = .shared

    enum Platform: String, Sendable, CaseIterable {
        case youTube = "YouTube"
        case instagram = "Instagram"
        case tikTok = "TikTok"
        case pinterest = "Pinterest"
        case facebook = "Facebook"
    }

    /// The platform a URL belongs to, or `nil` if it isn't a social link this
    /// importer handles.
    static func platform(for url: URL) -> Platform? {
        guard var host = url.host()?.lowercased() else { return nil }
        for prefix in ["www.", "m.", "mobile."] where host.hasPrefix(prefix) {
            host.removeFirst(prefix.count)
        }
        switch host {
        case "youtube.com", "youtu.be", "youtube-nocookie.com": return .youTube
        case "instagram.com", "instagr.am": return .instagram
        case "tiktok.com", "vm.tiktok.com", "vt.tiktok.com": return .tikTok
        case "pinterest.com", "pin.it": return .pinterest
        case "facebook.com", "fb.watch", "fb.com": return .facebook
        default:
            if host.hasPrefix("pinterest.") { return .pinterest }        // pinterest.de, .co.uk …
            if host.hasSuffix(".youtube.com") { return .youTube }
            if host.hasSuffix(".facebook.com") { return .facebook }
            return nil
        }
    }

    // MARK: - Entry points

    func importRecipe(from url: URL) async throws -> ImportedRecipe {
        guard let platform = Self.platform(for: url) else { throw RecipeImportError.noRecipeFound }
        let post = try await harvest(platform: platform, url: url)
        return try await buildRecipe(from: post, platform: platform)
    }

    /// Used by the in-app recipe finder, which already has the rendered DOM.
    func importRecipe(fromHTML html: String, sourceURL url: URL) async throws -> ImportedRecipe {
        guard let platform = Self.platform(for: url) else { throw RecipeImportError.noRecipeFound }
        var post = SocialPost(canonicalURL: url)
        await harvest(html: html, platform: platform, into: &post)
        return try await buildRecipe(from: post, platform: platform)
    }

    // MARK: - Harvesting

    private func harvest(platform: Platform, url: URL) async throws -> SocialPost {
        var post = SocialPost(canonicalURL: url)

        switch platform {
        case .youTube:
            let watchURL = Self.youTubeWatchURL(from: url) ?? url
            post.canonicalURL = watchURL
            let html = try await fetchHTML(from: watchURL, cookie: Self.youTubeConsentCookie)
            await harvestYouTube(html, into: &post)

        case .tikTok:
            if let oembed = try? await fetchOEmbed(
                "https://www.tiktok.com/oembed", for: url
            ) { post.merge(oembed) }
            if post.caption == nil, let html = try? await fetchHTML(from: url) {
                await harvest(html: html, platform: platform, into: &post)
            }

        case .instagram:
            // The /embed/captioned/ page carries the full caption and is not
            // behind Instagram's login wall, unlike the post page itself.
            if let shortcode = Self.instagramShortcode(from: url),
               let embedURL = URL(string: "https://www.instagram.com/p/\(shortcode)/embed/captioned/"),
               let html = try? await fetchHTML(from: embedURL) {
                Self.harvestInstagramEmbed(html, into: &post)
            }
            if post.caption == nil, let html = try? await fetchHTML(from: url) {
                await harvest(html: html, platform: platform, into: &post)
            }

        case .pinterest:
            let html = try await fetchHTML(from: url)
            await harvest(html: html, platform: platform, into: &post)
            post.outboundURL = Self.pinterestOutboundURL(in: html)

        case .facebook:
            let html = try await fetchHTML(from: url)
            await harvest(html: html, platform: platform, into: &post)
        }

        return post
    }

    /// Fill in whatever is still missing from a page's HTML.
    private func harvest(html: String, platform: Platform, into post: inout SocialPost) async {
        if platform == .youTube, post.transcript == nil || post.caption == nil {
            await harvestYouTube(html, into: &post)
        }
        if post.title == nil { post.title = Self.metaContent(["og:title", "twitter:title"], in: html) }
        if post.imageURLString == nil {
            post.imageURLString = Self.metaContent(["og:image", "twitter:image", "twitter:image:src"], in: html)
        }
        if post.caption == nil {
            let description = Self.metaContent(["og:description", "twitter:description", "description"], in: html)
            post.caption = platform == .instagram ? Self.unwrapInstagramDescription(description) : description
        }
    }

    // MARK: - YouTube

    private func harvestYouTube(_ html: String, into post: inout SocialPost) async {
        guard let objectText = Self.jsonObject(afterKey: "ytInitialPlayerResponse", in: html),
              let root = try? JSONSerialization.jsonObject(with: Data(objectText.utf8)) as? [String: Any]
        else { return }

        let details = root["videoDetails"] as? [String: Any]
        post.title = post.title ?? (details?["title"] as? String)
        post.author = post.author ?? (details?["author"] as? String)
        if post.caption == nil, let description = details?["shortDescription"] as? String, !description.isEmpty {
            post.caption = description
        }
        if post.imageURLString == nil,
           let thumbnails = ((details?["thumbnail"] as? [String: Any])?["thumbnails"]) as? [[String: Any]],
           let best = thumbnails.last, let urlString = best["url"] as? String {
            post.imageURLString = urlString
        }

        if post.transcript == nil,
           let tracks = ((((root["captions"] as? [String: Any])?["playerCaptionsTracklistRenderer"]) as? [String: Any])?["captionTracks"]) as? [[String: Any]],
           let track = Self.preferredCaptionTrack(tracks),
           let base = track["baseUrl"] as? String,
           let transcriptURL = URL(string: base.contains("fmt=") ? base : base + "&fmt=json3") {
            post.transcript = try? await fetchYouTubeTranscript(transcriptURL)
        }
    }

    private func fetchYouTubeTranscript(_ url: URL) async throws -> String? {
        let (data, _) = try await session.data(for: Self.request(for: url))
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let events = root["events"] as? [[String: Any]] else { return nil }
        var text = ""
        for event in events {
            guard let segments = event["segs"] as? [[String: Any]] else { continue }
            for segment in segments {
                if let piece = segment["utf8"] as? String { text += piece }
            }
        }
        let cleaned = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    static func preferredCaptionTrack(_ tracks: [[String: Any]]) -> [String: Any]? {
        let preferred = Locale.current.language.languageCode?.identifier.lowercased() ?? "en"
        func code(_ track: [String: Any]) -> String { (track["languageCode"] as? String ?? "").lowercased() }
        func isManual(_ track: [String: Any]) -> Bool { (track["kind"] as? String) != "asr" }
        return tracks.first(where: { code($0).hasPrefix(preferred) && isManual($0) })
            ?? tracks.first(where: { code($0).hasPrefix(preferred) })
            ?? tracks.first(where: { code($0).hasPrefix("en") })
            ?? tracks.first
    }

    static func youTubeWatchURL(from url: URL) -> URL? {
        let host = url.host()?.lowercased() ?? ""
        let segments = url.pathComponents.filter { $0 != "/" }

        if host.contains("youtu.be"), let id = segments.first {
            return URL(string: "https://www.youtube.com/watch?v=\(id)")
        }
        if let marker = segments.first, ["shorts", "live", "embed", "v"].contains(marker), segments.count > 1 {
            return URL(string: "https://www.youtube.com/watch?v=\(segments[1])")
        }
        if let v = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "v" })?.value {
            return URL(string: "https://www.youtube.com/watch?v=\(v)")
        }
        return nil
    }

    private static let youTubeConsentCookie = "CONSENT=YES+cb.20210328-17-p0.en+FX+000"

    // MARK: - Instagram

    static func instagramShortcode(from url: URL) -> String? {
        let segments = url.pathComponents.filter { $0 != "/" }
        guard let kindIndex = segments.firstIndex(where: { ["p", "reel", "reels", "tv"].contains($0) }),
              segments.indices.contains(kindIndex + 1) else { return nil }
        return segments[kindIndex + 1]
    }

    static func harvestInstagramEmbed(_ html: String, into post: inout SocialPost) {
        if let raw = firstCapture(
            #""edge_media_to_caption":\{"edges":\[\{"node":\{"text":"(.*?)"\}\}\]"#, in: html
        ) {
            post.caption = jsonUnescape(raw)
        } else if let block = firstCapture(
            #"<div class="Caption"[^>]*>(.*?)</div>"#, in: html
        ) {
            // The embed renders "<a>author</a> <caption…>" — drop the leading
            // username link, keep the rest as plain text.
            let withoutAuthor = block.replacingOccurrences(
                of: #"^\s*<a[^>]*>.*?</a>\s*"#, with: "", options: .regularExpression
            )
            post.caption = withoutAuthor.strippingHTML.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        }
        if post.imageURLString == nil {
            post.imageURLString = metaContent(["og:image", "twitter:image"], in: html)
        }
    }

    /// Instagram's `og:description` is `"1,234 likes, 56 comments - user on
    /// April 1, 2024: \"the real caption\""`. Keep only the quoted caption.
    static func unwrapInstagramDescription(_ description: String?) -> String? {
        guard let description, !description.isEmpty else { return nil }
        if let range = description.range(of: #": ""#) {
            var caption = String(description[range.upperBound...])
            if caption.hasSuffix("\"") { caption.removeLast() }
            return caption.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        }
        return description
    }

    // MARK: - Pinterest

    static func pinterestOutboundURL(in html: String) -> URL? {
        let patterns = [
            #""link":"(https?:\\?/\\?/[^"]+)""#,
            #"property\s*=\s*['"]og:see_also['"][^>]*content\s*=\s*['"]([^'"]+)"#,
        ]
        for pattern in patterns {
            guard let raw = firstCapture(pattern, in: html) else { continue }
            let unescaped = raw.replacingOccurrences(of: #"\/"#, with: "/")
            guard let url = URL(string: unescaped),
                  url.scheme?.hasPrefix("http") == true,
                  platform(for: url) == nil,
                  url.host()?.lowercased().contains("pinterest") != true else { continue }
            return url
        }
        return nil
    }

    // MARK: - oEmbed

    private func fetchOEmbed(_ endpoint: String, for url: URL) async throws -> SocialPost {
        guard var components = URLComponents(string: endpoint) else { throw RecipeImportError.notReachable }
        components.queryItems = [URLQueryItem(name: "url", value: url.absoluteString)]
        guard let requestURL = components.url else { throw RecipeImportError.notReachable }

        let (data, _) = try await session.data(for: Self.request(for: requestURL))
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        var post = SocialPost(canonicalURL: url)
        post.caption = (object["title"] as? String)?.nilIfEmpty
        post.author = (object["author_name"] as? String)?.nilIfEmpty
        post.imageURLString = (object["thumbnail_url"] as? String)?.nilIfEmpty
        return post
    }

    // MARK: - Build

    private func buildRecipe(from post: SocialPost, platform: Platform) async throws -> ImportedRecipe {
        // A Pinterest pin usually just points at a real recipe site — import
        // that page properly instead of guessing from the pin's blurb.
        if let outbound = post.outboundURL,
           let real = try? await RecipeSchemaParser(session: session).importRecipe(from: outbound),
           !real.ingredientLines.isEmpty || !(real.instructions ?? "").isEmpty {
            var copy = real
            if copy.imageData == nil, copy.imageURLString == nil { copy.imageURLString = post.imageURLString }
            return copy
        }

        let blob = [
            post.title,
            post.author.map { String(localized: "by \($0)") },
            post.caption,
            post.transcript.map { String(localized: "Transcript:\n\($0)") },
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty }
        .joined(separator: "\n\n")

        guard blob.count >= 40 else { throw RecipeImportError.noRecipeFound }

        let draft = await RecipeExtractor.extract(from: blob, source: .socialPost)

        let name = draft.name.nilIfEmpty
            ?? post.title.map(Self.cleanTitle)?.nilIfEmpty
            ?? platform.rawValue
        var recipe = ImportedRecipe(name: name, sourceURL: post.canonicalURL)
        recipe.ingredientLines = draft.ingredientLines
        recipe.instructions = draft.instructions.nilIfEmpty ?? post.caption?.nilIfEmpty
        recipe.imageURLString = post.imageURLString
        recipe.importedSourceApp = platform.rawValue
        // Always machine-extracted from loose text — the cook should look it over.
        recipe.needsReview = true

        guard !recipe.ingredientLines.isEmpty || !(recipe.instructions ?? "").isEmpty else {
            throw RecipeImportError.noRecipeFound
        }

        if let imageURLString = recipe.imageURLString,
           let imageURL = URL(string: imageURLString),
           imageURL.scheme?.hasPrefix("http") == true {
            recipe.imageData = await ImagePreparation.download(imageURL)
        }
        return recipe
    }

    /// YouTube titles trail off into "| Channel Name" or "- Easy 15 min recipe!!".
    static func cleanTitle(_ title: String) -> String {
        var cleaned = title
        for separator in [" | ", " – ", " — "] {
            if let range = cleaned.range(of: separator) { cleaned = String(cleaned[..<range.lowerBound]) }
        }
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - HTTP

    private func fetchHTML(from url: URL, cookie: String? = nil) async throws -> String {
        var request = Self.request(for: url)
        if let cookie { request.setValue(cookie, forHTTPHeaderField: "Cookie") }
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<400).contains(http.statusCode) {
            throw RecipeImportError.notReachable
        }
        if let string = String(data: data, encoding: .utf8) { return string }
        if let string = String(data: data, encoding: .isoLatin1) { return string }
        throw RecipeImportError.notReachable
    }

    static func request(for url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("text/html,application/xhtml+xml,application/json", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.timeoutInterval = 20
        return request
    }

    // MARK: - Parsing helpers

    /// The `{ … }` object literal that follows `"<key>" =` / `"<key>":` in a
    /// blob of JavaScript, found by balancing braces (so a lazy regex can't stop
    /// at the first nested `}`). Strings and their escapes are respected.
    static func jsonObject(afterKey key: String, in text: String) -> String? {
        let ns = text as NSString
        let anchor = ns.range(of: "\(key)")
        guard anchor.location != NSNotFound else { return nil }

        var index = anchor.location + anchor.length
        // Skip whitespace, ':' or '=' between the key and its object.
        while index < ns.length {
            let ch = Character(UnicodeScalar(ns.character(at: index))!)
            if ch == "{" { break }
            if ch == " " || ch == "\t" || ch == "\n" || ch == "\r" || ch == ":" || ch == "=" {
                index += 1; continue
            }
            return nil
        }
        guard index < ns.length else { return nil }

        let start = index
        var depth = 0
        var inString = false
        var escaped = false
        while index < ns.length {
            let ch = Character(UnicodeScalar(ns.character(at: index))!)
            if inString {
                if escaped { escaped = false }
                else if ch == "\\" { escaped = true }
                else if ch == "\"" { inString = false }
            } else {
                switch ch {
                case "\"": inString = true
                case "{": depth += 1
                case "}":
                    depth -= 1
                    if depth == 0 {
                        return ns.substring(with: NSRange(location: start, length: index - start + 1))
                    }
                default: break
                }
            }
            index += 1
        }
        return nil
    }

    static func metaContent(_ properties: [String], in html: String) -> String? {
        for property in properties {
            let escaped = NSRegularExpression.escapedPattern(for: property)
            let patterns = [
                #"<meta[^>]+(?:property|name)\s*=\s*['"]"# + escaped + #"['"][^>]+content\s*=\s*['"]([^'"]*)['"]"#,
                #"<meta[^>]+content\s*=\s*['"]([^'"]*)['"][^>]+(?:property|name)\s*=\s*['"]"# + escaped + #"['"]"#,
            ]
            for pattern in patterns {
                if let value = firstCapture(pattern, in: html)?.strippingHTML
                    .trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                    return htmlEntityDecode(value)
                }
            }
        }
        return nil
    }

    static func firstCapture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else { return nil }
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges > 1 else { return nil }
        return ns.substring(with: match.range(at: 1))
    }

    /// Turn the `\n`, `\"`, `\uXXXX` of a JSON string fragment back into text.
    static func jsonUnescape(_ raw: String) -> String {
        if let data = "\"\(raw)\"".data(using: .utf8),
           let decoded = try? JSONDecoder().decode(String.self, from: data) {
            return decoded
        }
        return raw
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\/", with: "/")
    }

    static func htmlEntityDecode(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&#x27;", with: "'")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&lt;", with: "<")
    }
}

/// The raw text harvested from a social post, before the model turns it into a
/// recipe.
struct SocialPost: Sendable {
    var canonicalURL: URL
    var title: String?
    var author: String?
    var caption: String?
    var transcript: String?
    var imageURLString: String?
    /// A Pinterest pin's outbound link to the real recipe site.
    var outboundURL: URL?

    mutating func merge(_ other: SocialPost) {
        title = title ?? other.title
        author = author ?? other.author
        caption = caption ?? other.caption
        transcript = transcript ?? other.transcript
        imageURLString = imageURLString ?? other.imageURLString
        outboundURL = outboundURL ?? other.outboundURL
    }
}
