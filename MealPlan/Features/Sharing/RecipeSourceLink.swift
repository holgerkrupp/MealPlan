import Foundation

/// Whether the page a recipe was saved from is still there to send someone to.
///
/// Recipe sites move, rename and die; a link that ends in a 404 is a worse
/// thing to share than no link at all. The check is deliberately lenient in
/// one direction only: the page counts as gone when the server says so (404,
/// 410) or the whole site no longer resolves. A bot wall, a rate limit or a
/// flaky connection proves nothing, so those stay `unknown` and the link is
/// still offered.
enum RecipeSourceLink {

    enum Availability: Equatable, Sendable {
        case checking
        case available
        case gone
        /// Couldn't tell — offline, blocked, or the server had a bad moment.
        case unknown
    }

    static func availability(forStatusCode code: Int) -> Availability {
        switch code {
        case 200..<400: .available
        case 404, 410: .gone
        default: .unknown
        }
    }

    static func availability(for error: any Error) -> Availability {
        guard let error = error as? URLError else { return .unknown }
        switch error.code {
        // The domain itself is gone — lapsed, or the blog shut down.
        case .cannotFindHost, .dnsLookupFailed: return .gone
        default: return .unknown
        }
    }

    static func check(_ url: URL, session: URLSession = .shared) async -> Availability {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return .gone
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        request.httpMethod = "HEAD"
        do {
            let (_, response) = try await session.data(for: request)
            let verdict = availability(forStatusCode: statusCode(of: response))
            if verdict == .available { return verdict }
            // Plenty of servers refuse HEAD (405, 403, even 404) while serving
            // the very same page to a browser, so a HEAD that says anything but
            // "fine" is asked again the way a browser would, one byte's worth.
            request.httpMethod = "GET"
            request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
            let (_, retry) = try await session.data(for: request)
            return availability(forStatusCode: statusCode(of: retry))
        } catch {
            return availability(for: error)
        }
    }

    private static func statusCode(of response: URLResponse) -> Int {
        (response as? HTTPURLResponse)?.statusCode ?? 0
    }
}
