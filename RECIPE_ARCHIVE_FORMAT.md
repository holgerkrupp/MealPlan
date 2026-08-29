# MealPlan recipe archive format

MealPlan exports one or more recipes as a single UTF-8 JSON file with the
extension `.mealplanrecipes`. Images are standard base64-encoded JSON `Data`
values. No compression, encryption, or proprietary database is involved.

The top-level object contains:

- `format`: always `MealPlan Recipe Archive`
- `version`: currently `1`
- `exportedAt`: an ISO-8601 timestamp
- `recipes`: an array of recipe objects

Each recipe stores its name, source URL, method, servings, preparation and
cooking times, tags, collections, rating, favorite state, placeholder glyph,
photos, and structured ingredients. Ingredient quantities use canonical grams,
millilitres, or pieces alongside the original display unit and raw text.

Importers should ignore unknown keys. A future MealPlan version will continue
to read version 1 archives; newer archive versions must increment `version`.
