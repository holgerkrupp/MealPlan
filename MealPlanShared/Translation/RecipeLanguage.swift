import Foundation
#if canImport(NaturalLanguage)
import NaturalLanguage
#endif

/// Language identity for recipe text: which language this device reads, which
/// language a recipe appears to be written in, and how to name one on screen.
///
/// Recipes arrive in whatever language their source used — a scanned German
/// cookbook, a Spanish blog, a friend's export. The cook, meanwhile, reads the
/// language they set on the device. These helpers are what tells the two apart.
enum RecipeLanguage {

    /// The language the cook reads: the first of the device's preferred
    /// languages, which is what iOS and macOS hand an app before it picks a
    /// localization of its own. Read once — the system restarts an app when
    /// its language changes, and this is asked for on every recipe screen.
    static let readerCode: String = Locale.preferredLanguages.first ?? Locale.current.identifier

    /// Languages offered in the translation picker. This mirrors the languages
    /// Apple Intelligence itself supports; the reader's own language is added
    /// on top by `offered(reader:)` so an unlisted one is never unreachable.
    /// The on-device model decides for itself what it can do — a language it
    /// declines simply comes back untranslated rather than wrong.
    static let commonCodes: [String] = [
        "en", "de", "fr", "es", "it", "pt-BR", "pt-PT", "nl", "da", "sv", "nb",
        "tr", "vi", "ja", "ko", "zh-Hans", "zh-Hant",
    ]

    /// The picker's list: the common languages, with the reader's own language
    /// first and never missing.
    static func offered(reader: String = readerCode) -> [String] {
        var codes = commonCodes.filter { !matches($0, reader) }
        codes.insert(canonical(reader), at: 0)
        return codes
    }

    /// The language's name in the *reader's* language ("German", "Deutsch"),
    /// falling back to the code itself for anything the system can't name.
    static func displayName(for code: String, in locale: Locale = .current) -> String {
        let canonical = canonical(code)
        if let name = locale.localizedString(forIdentifier: canonical.replacingOccurrences(of: "-", with: "_")) {
            return name
        }
        if let base = base(of: canonical), let name = locale.localizedString(forLanguageCode: base) {
            return name
        }
        return canonical
    }

    /// True when two language tags mean the same thing to a cook. Regional
    /// differences don't ("en-GB" and "en-US" are one language here), but a
    /// written script does: Simplified and Traditional Chinese are not
    /// interchangeable on the page.
    static func matches(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs, let rhs, let left = base(of: lhs), let right = base(of: rhs) else { return false }
        guard left == right else { return false }
        guard let leftScript = script(of: lhs), let rightScript = script(of: rhs) else { return true }
        return leftScript == rightScript
    }

    /// The language a piece of recipe text is written in, or `nil` when there
    /// isn't enough text to tell. Runs entirely on device.
    static func detect(_ text: String) -> String? {
        #if canImport(NaturalLanguage)
        let sample = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(600))
        guard sample.count >= 12 else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sample)
        guard let (language, confidence) = recognizer.languageHypotheses(withMaximum: 1).first,
              confidence >= 0.5 else { return nil }
        return language.rawValue
        #else
        return nil
        #endif
    }

    // MARK: - Tag arithmetic
    //
    // Deliberately string surgery rather than `Locale.Language`: the subtags
    // are all that's needed here, and reading them straight off the tag keeps
    // the comparison predictable (and testable) for tags that arrived from a
    // sync partner or an older release.

    /// A tidied tag: dashes rather than underscores, lowercase language,
    /// capitalized script, uppercase region.
    static func canonical(_ code: String) -> String {
        let parts = subtags(code)
        guard let language = parts.first?.lowercased() else { return code }
        return ([language] + parts.dropFirst().map { part in
            part.count == 4 ? part.capitalized : part.uppercased()
        }).joined(separator: "-")
    }

    /// The language subtag on its own ("de" out of "de-DE").
    static func base(of code: String) -> String? {
        subtags(code).first.map { $0.lowercased() }
    }

    /// The four-letter script subtag, when the tag names one ("Hans").
    static func script(of code: String) -> String? {
        subtags(code).dropFirst().first { $0.count == 4 }.map { $0.capitalized }
    }

    private static func subtags(_ code: String) -> [String] {
        code.replacingOccurrences(of: "_", with: "-")
            .split(separator: "-")
            .map(String.init)
            .filter { !$0.isEmpty }
    }
}
