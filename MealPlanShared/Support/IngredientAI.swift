import Foundation
import SwiftData

/// The small, non-persistent input sent to an ingredient classifier. It never
/// contains a recipe library or SwiftData objects.
struct IngredientMatchRequest: Equatable, Sendable {
    var rawName: String
    var candidateName: String
    var localeIdentifier: String
    var note: String?
    var category: IngredientCategory?
    var dimension: QuantityDimension?

    init(
        rawName: String,
        candidateName: String,
        localeIdentifier: String = Locale.current.identifier,
        note: String? = nil,
        category: IngredientCategory? = nil,
        dimension: QuantityDimension? = nil
    ) {
        self.rawName = rawName
        self.candidateName = candidateName
        self.localeIdentifier = localeIdentifier
        self.note = note
        self.category = category
        self.dimension = dimension
    }
}

enum IngredientAIConfidence: String, CaseIterable, Codable, Sendable {
    case low
    case medium
    case high
    case unknown
}

/// A classifier's structured second opinion. `rationale` is intentionally
/// transient: the app may show it during review, but never caches model prose.
struct IngredientAIResult: Equatable, Sendable {
    var sameIngredient: Bool
    var confidence: IngredientAIConfidence
    var rationale: String?

    init(sameIngredient: Bool, confidence: IngredientAIConfidence, rationale: String? = nil) {
        self.sameIngredient = sameIngredient
        self.confidence = confidence
        self.rationale = rationale
    }
}

/// Test doubles and future on-device classifiers implement this boundary.
protocol IngredientClassifier: Sendable {
    func classify(_ request: IngredientMatchRequest) async -> IngredientAIResult?
}

struct IngredientMatchCandidate: Equatable, Sendable, Identifiable {
    let id: UUID
    let name: String
    let category: IngredientCategory

    init(id: UUID = UUID(), name: String, category: IngredientCategory = .other) {
        self.id = id
        self.name = name
        self.category = category
    }
}

enum IngredientMatchResolution: Equatable, Sendable {
    case deterministic(IngredientMatchCandidate)
    case aiSuggestion(IngredientMatchSuggestion)
    case keepSeparate
    case unresolved
}

struct IngredientMatchSuggestion: Equatable, Sendable {
    let candidate: IngredientMatchCandidate
    let result: IngredientAIResult
    let request: IngredientMatchRequest
}

/// Resolves identity without touching SwiftData. The caller decides whether
/// to show a suggestion and explicitly calls `IngredientMatchLearning` after
/// a person confirms or rejects it.
enum IngredientMatchResolver {
    static func resolve(
        rawName: String,
        candidates: [IngredientMatchCandidate],
        rules: [IngredientMatchRule] = [],
        requestContext: RequestContext = .init(),
        classifier: (any IngredientClassifier)? = nil
    ) async -> IngredientMatchResolution {
        let rawKey = IngredientMatching.key(for: rawName)
        guard !rawKey.isEmpty else { return .unresolved }

        if rules.contains(where: { rule in
            rule.kind == .keepSeparate && candidates.contains {
                rule.applies(to: rawKey, and: IngredientMatching.key(for: $0.name))
            }
        }) {
            return .keepSeparate
        }

        if let exact = candidates.first(where: { Ingredient.normalize($0.name) == Ingredient.normalize(rawName) }) {
            return .deterministic(exact)
        }

        if let alias = candidates.first(where: { candidate in
            rules.contains { $0.kind == .alias && $0.applies(to: rawKey, and: IngredientMatching.key(for: candidate.name)) }
        }) {
            return .deterministic(alias)
        }

        let deterministic = candidates.filter {
            IngredientMatching.keysMatch(rawKey, IngredientMatching.key(for: $0.name), rules: rules)
        }
        if deterministic.count == 1, let only = deterministic.first {
            return .deterministic(only)
        }
        guard let classifier, let candidate = deterministic.first ?? candidates.first else {
            return .unresolved
        }

        let request = IngredientMatchRequest(
            rawName: rawName,
            candidateName: candidate.name,
            localeIdentifier: requestContext.localeIdentifier,
            note: requestContext.note,
            category: candidate.category,
            dimension: requestContext.dimension
        )
        guard let result = await classifier.classify(request) else { return .unresolved }
        return .aiSuggestion(IngredientMatchSuggestion(candidate: candidate, result: result, request: request))
    }

    struct RequestContext: Sendable {
        var localeIdentifier: String
        var note: String?
        var dimension: QuantityDimension?

        init(localeIdentifier: String = Locale.current.identifier, note: String? = nil, dimension: QuantityDimension? = nil) {
            self.localeIdentifier = localeIdentifier
            self.note = note
            self.dimension = dimension
        }
    }
}

/// The only API that persists a learned outcome. Keeping this separate from
/// classification makes it impossible for model output to mutate SwiftData.
@MainActor
enum IngredientMatchLearning {
    @discardableResult
    static func learn(
        _ kind: IngredientMatchRuleKind,
        for firstName: String,
        and secondName: String,
        in household: Household,
        context: ModelContext
    ) -> IngredientMatchRule {
        let firstKey = IngredientMatching.key(for: firstName)
        let secondKey = IngredientMatching.key(for: secondName)
        let existing = (household.matchRules ?? []).first {
            $0.kind == kind && $0.applies(to: firstKey, and: secondKey)
        }
        if let existing { return existing }

        let rule = IngredientMatchRule(leftName: firstName, rightName: secondName, kind: kind)
        rule.household = household
        context.insert(rule)
        try? context.save()
        return rule
    }

    static func learnAlias(
        _ firstName: String,
        and secondName: String,
        in household: Household,
        context: ModelContext
    ) -> IngredientMatchRule {
        learn(.alias, for: firstName, and: secondName, in: household, context: context)
    }

    static func learnKeepSeparate(
        _ firstName: String,
        and secondName: String,
        in household: Household,
        context: ModelContext
    ) -> IngredientMatchRule {
        learn(.keepSeparate, for: firstName, and: secondName, in: household, context: context)
    }
}

#if canImport(FoundationModels) && !os(watchOS)
import FoundationModels

@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
struct FoundationModelsIngredientClassifier: IngredientClassifier {
    static var availability: IngredientAIAvailability {
        SystemLanguageModel.default.isAvailable ? .available : .unavailable
    }

    func classify(_ request: IngredientMatchRequest) async -> IngredientAIResult? {
        guard Self.availability == .available else { return nil }

        let session = LanguageModelSession(instructions: """
            Classify whether two ingredient descriptions refer to the same grocery item.
            Be conservative: a meaningful product qualifier such as 'red', 'minced',
            or 'chopped' usually means they are different. Return only the requested
            structured fields. Do not infer from information not present in the input.
            """)
        let prompt = """
        Raw ingredient: \(request.rawName)
        Candidate canonical ingredient: \(request.candidateName)
        Locale: \(request.localeIdentifier)
        Note: \(request.note ?? "none")
        Category: \(request.category?.rawValue ?? "unknown")
        Dimension: \(request.dimension?.rawValue ?? "unknown")
        """

        do {
            let response = try await session.respond(to: prompt, generating: GeneratedIngredientMatch.self)
            return IngredientAIResult(
                sameIngredient: response.content.sameIngredient,
                confidence: IngredientAIConfidence(rawValue: response.content.confidence.lowercased()) ?? .unknown,
                rationale: response.content.rationale.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        } catch {
            return nil
        }
    }
}

@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
enum IngredientAIAvailability: Equatable, Sendable {
    case available
    case unavailable
}

@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
@Generable
private struct GeneratedIngredientMatch {
    var sameIngredient: Bool
    var confidence: String
    var rationale: String
}
#else
enum IngredientAIAvailability: Equatable, Sendable {
    case unavailable
}
#endif
