# Ease-of-use reduction

## Label proposal and conversion

MealPlan previously exposed five ways to label a dish: collections, tags,
meal-type tags, dietary flags, and season. The implemented model exposes three:

- Tags are the general-purpose vocabulary and absorb collections and dietary
  labels.
- Meal type remains structured because it suggests a planning slot.
- Season remains structured because it drives seasonal suggestions.

Before the one-time conversion clears either retired field, MealPlan writes a
photo-inclusive backup to the app group's `MigrationBackups` directory and
decodes it again to verify it. Existing tags, collections, and localized dietary
labels are normalized through `DishTag.merge`, so `vegan`, `Vegan`, and the old
`.vegan` flag produce one tag. A per-household version marker makes the
conversion idempotent. Old archive fields remain decodable, but every import,
restore, and incoming shared record immediately consolidates them into tags.

## Measurements

Tap counts start at the first cold-install onboarding screen, count every
button or row selection, and exclude typing a dish name. The baseline assumes
the shortest successful path through the previous six-page onboarding, adding
a name-only dish, then selecting it for a meal.

| Cumulative change | Concepts to learn | Taps to first planned meal | Nearby task reduced |
| --- | ---: | ---: | --- |
| Before Part 4 | 14 | 13 | — |
| Collections and dietary flags become tags | 12 | 13 | Five dish-label controls become three. |
| Connections replaces three integration sections | 12 | 13 | Top-level settings sections fall from 11 to 9; connection status is visible without opening a detail screen. |
| Serving, meal-slot, and pantry actions move into context | 11 | 13 | Standard servings from a dish: 4 taps to 0; meal slots from the calendar: 4 to 2; pantry staples from the shopping list: 4 to 2. |
| Selectable starter dishes in onboarding | 11 | 9 | No dish-creation detour; after onboarding, tap a meal and a starter dish. |
| The free horizon is visible with a calendar boundary | 11 | 9 | Understanding why a later day is locked: one failed planning attempt plus dismissal becomes 0. |

The extra starter-selection page is included in the final count. Its defaults
require no additional tap, and every starter is a normal dish that can be
edited or deleted.
