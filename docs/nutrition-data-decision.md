# Nutrition data decision

Research date: 2026-11-24. Meals does not bundle FoodData Central or call a paid nutrition API.

The existing estimator uses a small, redistributable, bundled reference table for generic ingredients and lets households enter package values or preserve imported recipe values. This is a better fit for an offline-first app than shipping a large branded-product dataset: it avoids API keys, account identifiers, network latency, redistribution ambiguity, and a maintenance promise that the small project cannot support. The table is explicitly described as approximate and is not medical advice.

FoodData Central was reviewed as the closest public alternative. USDA publishes its data under CC0 1.0 and requests source attribution, but the API requires a data.gov key, has request limits, and is primarily a U.S. food and branded-product source. That is a poor default for local recipe estimation: it would add credentials, network failure modes, and U.S.-centric coverage without reliably improving generic German/English ingredient matching. See [USDA FoodData Central licensing](https://fdc.nal.usda.gov/) and the [API guide](https://fdc.nal.usda.gov/api-guide/). No FoodData Central payload or key is bundled or sent by Meals.

The estimator now exposes line provenance (`NutritionSource`), the canonical ingredient matched, deterministic match confidence, incomplete coverage, and a distinct quality state. Unknown ingredients, unknown density conversions, and unknown nutrients remain unknown rather than becoming zero; a known zero such as water remains a counted zero. Unit parsing normalizes metric, imperial, English and German recipe/container units before the estimator applies ingredient-specific density or piece-weight conversions. Imported and manually entered values continue to win over the generic table and remain untouched.

FoodData Central remains a possible future optional source only if a concrete privacy, licensing, localization, and maintenance review justifies it. No claim of USDA-backed or allergen-free analysis is made.
