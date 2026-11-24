# Nutrition data decision

Research date: 2026-11-24. Meals does not bundle FoodData Central or call a paid nutrition API.

The existing estimator uses a small, redistributable, bundled reference table for generic ingredients and lets households enter package values or preserve imported recipe values. This is a better fit for an offline-first app than shipping a large branded-product dataset: it avoids API keys, account identifiers, network latency, redistribution ambiguity, and a maintenance promise that the small project cannot support. The table is explicitly described as approximate and is not medical advice.

The estimator now exposes line provenance (`NutritionSource`), deterministic matching disclosure, incomplete coverage, and a distinct quality state. Unknown ingredients and unknown nutrients remain unknown rather than becoming zero. Unit parsing already normalizes metric, common German recipe units, and imperial mass/volume units before the estimator applies ingredient-specific density or piece-weight conversions.

FoodData Central remains a possible future optional source only if a concrete privacy, licensing, localization, and maintenance review justifies it. No claim of USDA-backed or allergen-free analysis is made.
