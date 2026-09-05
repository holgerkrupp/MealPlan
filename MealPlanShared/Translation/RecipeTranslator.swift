import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Translates a recipe's ingredients and directions with Apple Intelligence's
/// on-device model.
///
/// The recipe never leaves the device, which is the whole reason to translate
/// it here rather than through a web service: a family's recipe collection is
/// personal, and a translation is worth having offline in the kitchen.
///
/// The text is sent in small batches — a batch is one line-for-line request,
/// so the model can't re-flow a recipe into prose, and a long recipe can't run
/// past the on-device context window. A batch the model declines keeps its
/// original wording instead of losing it.
enum RecipeTranslator {

    // MARK: - Availability

    enum Availability: Sendable, Equatable {
        case ready
        /// Apple Intelligence is switched off in Settings.
        case appleIntelligenceOff
        /// Supported, but the model is still downloading (or the device is too
        /// low on battery or storage to load it right now).
        case modelNotReady
        /// This device or OS can't run the on-device model at all.
        case unsupported

        var isReady: Bool { self == .ready }

        /// What to tell the cook when translation isn't offered.
        var explanation: String? {
            switch self {
            case .ready:
                nil
            case .appleIntelligenceOff:
                String(localized: "Turn on Apple Intelligence in Settings to translate recipes on this device.")
            case .modelNotReady:
                String(localized: "Apple Intelligence is still getting ready. Try again in a little while.")
            case .unsupported:
                String(localized: "This device can’t translate recipes on its own — Apple Intelligence isn’t available on it.")
            }
        }
    }

    static var availability: Availability {
        #if canImport(FoundationModels)
        switch SystemLanguageModel.default.availability {
        case .available:
            return .ready
        case .unavailable(let reason):
            switch reason {
            case .appleIntelligenceNotEnabled: return .appleIntelligenceOff
            case .modelNotReady: return .modelNotReady
            default: return .unsupported
            }
        }
        #else
        return .unsupported
        #endif
    }

    enum Failure: Error, LocalizedError, Equatable {
        case unavailable
        case nothingToTranslate
        case modelDeclined

        var errorDescription: String? {
            switch self {
            case .unavailable:
                RecipeTranslator.availability.explanation
                    ?? String(localized: "Recipes can’t be translated on this device.")
            case .nothingToTranslate:
                String(localized: "This recipe has no ingredients or steps to translate yet.")
            case .modelDeclined:
                String(localized: "The translation didn’t come back. Please try again.")
            }
        }
    }

    // MARK: - Translating

    /// Translates a recipe into `languageCode`, reporting progress from 0 to 1
    /// as batches come back so the sheet can show how far along it is.
    static func translate(
        _ request: RecipeTranslationRequest,
        into languageCode: String,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> RecipeTranslation {
        guard !request.isEmpty else { throw Failure.nothingToTranslate }
        guard availability.isReady else { throw Failure.unavailable }

        let (slots, texts) = plan(request)
        guard !texts.isEmpty else { throw Failure.nothingToTranslate }

        let batches = RecipeTranslationBatcher.batches(of: texts)
        var results = [String?](repeating: nil, count: texts.count)
        var translatedAnything = false

        for (index, batch) in batches.enumerated() {
            let lines = Array(texts[batch])
            if let translated = await translateBatch(lines, into: languageCode, source: request.sourceLanguageCode) {
                for (offset, value) in translated.enumerated() {
                    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { continue }
                    results[batch.lowerBound + offset] = trimmed
                    translatedAnything = true
                }
            }
            progress(Double(index + 1) / Double(batches.count))
        }

        guard translatedAnything else { throw Failure.modelDeclined }
        return assemble(request, slots: slots, results: results, languageCode: languageCode)
    }

    // MARK: - Laying the recipe out as a list of lines

    /// Where one translated line belongs once it comes back.
    private enum Slot: Sendable {
        case name
        case ingredientName(Int)
        case ingredientNote(Int)
        case direction(Int)
    }

    private static func plan(_ request: RecipeTranslationRequest) -> ([Slot], [String]) {
        var slots: [Slot] = []
        var texts: [String] = []

        let name = request.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty {
            slots.append(.name)
            texts.append(name)
        }
        for (index, line) in request.ingredients.enumerated() {
            slots.append(.ingredientName(index))
            texts.append(line.name)
            if let note = line.note, !note.isEmpty {
                slots.append(.ingredientNote(index))
                texts.append(note)
            }
        }
        for (index, line) in request.directions.translatableLines.enumerated() {
            slots.append(.direction(index))
            texts.append(line)
        }
        return (slots, texts)
    }

    private static func assemble(
        _ request: RecipeTranslationRequest,
        slots: [Slot],
        results: [String?],
        languageCode: String
    ) -> RecipeTranslation {
        var name = request.name
        var ingredientNames = request.ingredients.map(\.name)
        var ingredientNotes = request.ingredients.map(\.note)
        // A line the model didn't return keeps its own wording, so the step
        // numbering and paragraph shape of the directions still line up.
        var directions = request.directions.translatableLines

        for (index, slot) in slots.enumerated() {
            guard let value = results[index] else { continue }
            switch slot {
            case .name: name = value
            case .ingredientName(let line): ingredientNames[line] = value
            case .ingredientNote(let line): ingredientNotes[line] = value
            case .direction(let line): directions[line] = value
            }
        }

        return RecipeTranslation(
            languageCode: RecipeLanguage.canonical(languageCode),
            name: name,
            ingredients: request.ingredients.enumerated().map { index, line in
                RecipeTranslation.IngredientLine(
                    id: line.id,
                    name: ingredientNames[index],
                    note: ingredientNotes[index]
                )
            },
            directionsText: request.directions.rebuilt(with: directions)
        )
    }

    // MARK: - One request to the model

    /// Translates one batch, halving it and trying again when the model turns
    /// it down — usually because the batch ran past the context window, or
    /// because it answered with a different number of lines than it was given.
    /// Returns `nil` when even a single line wouldn't go through.
    private static func translateBatch(
        _ lines: [String],
        into languageCode: String,
        source: String?
    ) async -> [String]? {
        #if canImport(FoundationModels)
        guard !lines.isEmpty else { return [] }
        if let translated = await respond(to: lines, into: languageCode, source: source) {
            return translated
        }
        guard lines.count > 1 else { return nil }
        // One request at a time: the on-device model is a shared resource, and
        // a recipe that overflowed once is not helped by asking twice at once.
        let middle = lines.count / 2
        guard let head = await translateBatch(Array(lines[..<middle]), into: languageCode, source: source),
              let tail = await translateBatch(Array(lines[middle...]), into: languageCode, source: source)
        else { return nil }
        return head + tail
        #else
        return nil
        #endif
    }

    #if canImport(FoundationModels)
    /// One batch of recipe lines, translated in place.
    @Generable
    struct TranslatedLines {
        @Guide(description: "The translated entries, one for each numbered entry that was given, in the same order and with the same count. Quantities, units and numbers are copied over unchanged.")
        var lines: [String]
    }

    private static func respond(to lines: [String], into languageCode: String, source: String?) async -> [String]? {
        let session = LanguageModelSession(instructions: instructions(for: languageCode, source: source))
        let numbered = lines.enumerated()
            .map { "\($0.offset + 1). \($0.element)" }
            .joined(separator: "\n")
        do {
            let response = try await session.respond(
                to: "Translate these \(lines.count) entries:\n\(numbered)",
                generating: TranslatedLines.self
            ).content
            // A different number of lines back means the model merged or split
            // entries; the caller keeps the original wording rather than
            // pairing translations with the wrong ingredients.
            guard response.lines.count == lines.count else { return nil }
            return response.lines
        } catch {
            return nil
        }
    }

    private static func instructions(for languageCode: String, source: String?) -> String {
        let target = RecipeLanguage.displayName(for: languageCode, in: Locale(identifier: "en"))
        let from = source.map { " from \(RecipeLanguage.displayName(for: $0, in: Locale(identifier: "en")))" } ?? ""
        return """
        You translate parts of a cooking recipe\(from) into \(target) (\(RecipeLanguage.canonical(languageCode))).
        You are given numbered entries: a dish name, ingredient lines, notes, or preparation steps. \
        Return exactly one translated entry for each entry you were given, in the same order, and \
        nothing else. Never merge, split, number, explain, shorten or add entries.
        Copy every number, quantity, unit and temperature over exactly as it appears — never convert \
        grams to ounces, millilitres to cups, or Celsius to Fahrenheit. Use the words a cook in \
        \(target) would use for ingredients and techniques. Leave brand names, proper names and \
        anything already written in \(target) as it is.
        """
    }
    #endif
}

/// Cuts the lines of a recipe into batches small enough for one on-device
/// request. Kept separate from the model so the sizing rules can be reasoned
/// about — and tested — on their own.
enum RecipeTranslationBatcher {
    /// Lines per request. Small batches keep each response short enough that
    /// the model reliably returns one entry per line.
    static let defaultMaximumLines = 8
    /// Characters per request, counted across the batch. One very long step
    /// becomes a batch of its own rather than being cut in half mid-sentence.
    static let defaultMaximumCharacters = 900

    static func batches(
        of texts: [String],
        maximumLines: Int = defaultMaximumLines,
        maximumCharacters: Int = defaultMaximumCharacters
    ) -> [Range<Int>] {
        var batches: [Range<Int>] = []
        var start = 0
        var characters = 0

        for (index, text) in texts.enumerated() {
            let wouldOverflow = index > start
                && (index - start >= maximumLines || characters + text.count > maximumCharacters)
            if wouldOverflow {
                batches.append(start..<index)
                start = index
                characters = 0
            }
            characters += text.count
        }
        if start < texts.count { batches.append(start..<texts.count) }
        return batches
    }
}
