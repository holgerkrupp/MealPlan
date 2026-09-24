# Ingredient matching and Apple Intelligence

MealPlan always resolves ingredient identity locally first. Exact canonical
names, confirmed aliases, and the existing conservative matcher remain the
normal path and are used by shopping-list generation without any model call.

The optional `IngredientMatchResolver` is an explicit asynchronous review
boundary for a raw ingredient and a candidate canonical ingredient. A caller
may inject `FoundationModelsIngredientClassifier` when
`SystemLanguageModel` reports that Apple Intelligence is available. The
classifier receives only the two ingredient descriptions, locale, note, and
helpful category/unit context. It never receives the recipe library or a
SwiftData object.

The classifier returns a structured suggestion: `sameIngredient`, a bounded
confidence value, and a short rationale. The suggestion is not a merge and
cannot write SwiftData. A user-confirmed outcome is persisted explicitly with
`IngredientMatchLearning.learnAlias` or `learnKeepSeparate`. These decisions
are household data, so they are included in CloudKit sync and MealPlan
backups. The rationale is deliberately not stored.

Keep-separate decisions take precedence over fuzzy matching everywhere the
rule-aware matcher is used. If Foundation Models is unavailable, the
classifier is omitted and the deterministic behavior is unchanged.
