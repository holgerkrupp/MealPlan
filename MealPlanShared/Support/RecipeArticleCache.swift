import CryptoKit
import Foundation

/// A bounded, local-only cache for article HTML. No model points at these
/// files, so SwiftData/CloudKit and backups cannot accidentally upload them.
actor RecipeArticleCache {
    static let shared = RecipeArticleCache()

    private let byteLimit = 12 * 1_024 * 1_024
    private let fileLimit = 40

    func articleHTML(for url: URL) async throws -> String {
        let file = cacheFile(for: url)
        if let data = try? Data(contentsOf: file), let html = String(data: data, encoding: .utf8) {
            try? FileManager.default.setAttributes([.modificationDate: Date.now], ofItemAtPath: file.path)
            return html
        }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw RecipeFeedParserError.httpStatus((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        guard let html = String(data: data, encoding: .utf8) else {
            throw RecipeFeedParserError.unsupportedFormat
        }
        try store(html, for: url)
        return html
    }

    func store(_ html: String, for url: URL) throws {
        let directory = cacheDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(html.utf8).write(to: cacheFile(for: url), options: .atomic)
        trim(directory)
    }

    private var cacheDirectory: URL {
        let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: SharedStore.appGroupID)
            ?? URL.cachesDirectory
        return root.appending(path: "RecipeArticleCache", directoryHint: .isDirectory)
    }

    private func cacheFile(for url: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return cacheDirectory.appending(path: "\(digest).html")
    }

    private func trim(_ directory: URL) {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        guard var files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]
        ) else { return }
        files = files.filter { (try? $0.resourceValues(forKeys: keys).isRegularFile) == true }
        files.sort {
            let lhs = try? $0.resourceValues(forKeys: keys).contentModificationDate
            let rhs = try? $1.resourceValues(forKeys: keys).contentModificationDate
            return (lhs ?? .distantPast) > (rhs ?? .distantPast)
        }
        var bytes = 0
        for (index, file) in files.enumerated() {
            let size = (try? file.resourceValues(forKeys: keys).fileSize) ?? 0
            bytes += size
            if index >= fileLimit || bytes > byteLimit { try? FileManager.default.removeItem(at: file) }
        }
    }
}

enum RecipeArticleText {
    static func extract(fromHTML html: String) -> String {
        var body = html
        for element in ["script", "style", "nav", "footer", "header", "aside", "form"] {
            body = body.replacingOccurrences(
                of: "<\(element)\\b[^>]*>[\\s\\S]*?</\(element)>",
                with: " ",
                options: [.regularExpression, .caseInsensitive]
            )
        }
        body = body.replacingOccurrences(of: "</(p|div|li|h[1-6]|br|section|article)>", with: "\n", options: [.regularExpression, .caseInsensitive])
        body = body.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        body = body
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\n\\s*\\n\\s*\\n+", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return body
    }
}
