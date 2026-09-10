import Foundation

/// Names for files that leave the app — a recipe PDF, a `.mealplanrecipes`
/// archive — so the person receiving one sees "Pfannkuchen.pdf" in their
/// Downloads or AirDrop sheet rather than a string of hex.
enum ShareFileName {

    /// The name with only what a file system actually refuses taken out.
    /// Umlauts, accents, CJK and emoji all survive: they are the recipe's name.
    static func sanitized(_ name: String, fallback: String) -> String {
        let refused = CharacterSet(charactersIn: #"/\:?%*|"<>"#)
            .union(.newlines)
            .union(.controlCharacters)
        let cleaned = name
            .components(separatedBy: refused)
            .joined(separator: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            // A leading dot hides the file; a trailing one confuses the extension.
            .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ".")))
        let clipped = String(cleaned.prefix(80)).trimmingCharacters(in: .whitespaces)
        return clipped.isEmpty ? fallback : clipped
    }

    /// A file URL in a directory of its own under the temporary directory.
    ///
    /// The directory, not the name, is what keeps two shares of the same
    /// recipe apart, so the name itself can stay clean.
    static func stagingURL(for name: String, fallback: String, pathExtension: String) throws -> URL {
        try stagingDirectory()
            .appending(path: sanitized(name, fallback: fallback))
            .appendingPathExtension(pathExtension)
    }

    /// A fresh, empty directory for a batch of files shared together.
    static func stagingDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "Shared-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
