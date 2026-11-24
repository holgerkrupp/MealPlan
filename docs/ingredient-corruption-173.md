# Issue #173 regression audit

Status: implemented and validated in the simulator-focused suites. The
affected production store was not available, so the historical screenshot
shape remains classified as legacy evidence rather than a proven origin.

## Root-cause finding

One active parser defect was verified by source inspection and pinned by
`microdataAliasPropertiesDoNotDuplicateOneDOMIngredient`:

* `parseMicrodataCandidates` collects every `itemprop` token into separate
  `recipeingredient` and `ingredients` arrays, then concatenates both arrays.
  A single DOM node marked `itemprop="recipeIngredient ingredients"` therefore
  appears twice. The parser now prefers the canonical `recipeIngredient`
  property and uses `ingredients` only as a fallback. This was a current,
  reproducible duplication path; it did not require legacy data or CloudKit.

The ordinary JSON-LD path now scores structured candidates together and chooses
one target recipe, preferring the visible recipe title and complete content.
The fixture with a complete target and a sparse related recipe records that
contract. A malformed page can still publish a misleading candidate, and an
affected user store/source page was not provided.

The importer/refresh graph is structurally capable of preserving isolation:
each incoming raw line creates one `DishIngredient`, canonical `Ingredient`
objects are shared intentionally, and repeated import planning skips the same
recipe. Refresh replaces the target dish's rows, so the new fixtures assert
that counts remain bounded and another dish is unchanged. These are code-path
and fixture checks, not a claim that the current unbuildable checkout passed
them.

The screenshot-shaped legacy fixture is deliberately represented as three
distinct line UUIDs with identical `rawText` (`225 g ground beef`), an
unrelated canonical name (`Schweinenacken ohne Knochen`), and `10 ml`
volume. This is a valid persisted corruption shape and is not normalized or
deleted by the test. The auditor assertions require it to remain a review
finding with all evidence attached. No affected production store was
available, so whether the screenshot came from an old import, refresh, or
sync replay remains unverified.

## Regression matrix

`MealPlanTests/IngredientCorruptionRegressionTests.swift` covers:

* fresh import: one persisted line per source line, unique line UUIDs, exact
  raw text, canonical IDs/names, quantities, dimensions, and owning dish;
* repeated import: no second dish, no additional line UUIDs, and unchanged
  line snapshots;
* repeated refresh: bounded replacement on the selected dish only, with no
  cross-recipe movement or quantity/dimension drift;
* overlapping canonical ingredients: shared catalogue IDs but disjoint,
  recipe-owned line IDs;
* two structured recipe objects: selected target is not mixed with a related
  recipe's ingredient;
* the verified microdata alias duplication fixture;
* MealPlan archive restore: raw text, canonical names, quantities, dimensions,
  ownership, and new line identity survive the archive boundary;
* repeated identical `MPDishIngredient` CloudKit application on a disk-backed
  SwiftData store: one row, stable UUID, one inverse reference, and preserved
  payload values;
* disk-store close/reopen: line UUIDs, raw text, quantity dimensions, and
  owning-dish relationships survive persistence reload;
* repeated inverse reference: classified as safe only when it is the same
  persistent line object;
* distinct line objects sharing one UUID: classified as `cannotDetermine`,
  never a safe automatic repair;
* two sequential model contexts: edits to recipe A do not move or overwrite
  recipe B's line;
* legacy triples and wrong canonical identity: read-only audit evidence;
* cleanup of duplicate catalogue rows does not delete legitimate sauce/garnish
  lines with different roles, amounts, dimensions, and notes.

## CloudKit and cleanup protections

CloudKit record identity was already UUID-based, so replay alone did not
create new rows in the inspected code. The active integrity risks were
unconditional relationship reassignment, stale out-of-order payloads, and
duplicate records in one sync batch. The applier now guards relationship
changes, rejects stale payloads/tombstones, deduplicates remote records, and
scopes its temporary UUID lookup cache per model context.

The Settings path is **Ingredient Cleanup → Check recipe ingredients**. The
scan is read-only and reports affected recipes, original `rawText`, canonical
ingredient, quantities/dimensions, relationship evidence, and a classification
of safe automatic repair, review recommended, or cannot determine. Only a
repeated reference to the same persistent line object is repaired automatically;
distinct rows with identical content or UUIDs remain review-only. Reviewed
canonical reassignment preserves raw text and quantity. Reviewed line removal
does not alter shopping, pantry, meal, or household rows. Each mutation creates
a durable whole-store recovery archive using the existing recovery mechanism,
and the UI also offers undo.

## Verified versus hypothesis

Verified from the current source and fixtures:

1. A single microdata element could be counted twice by the parser; the active
   path is now fixed.
2. `DishIngredient` is the persisted join row; the UI's sorted relationship
   does not synthesize three copies.
3. Canonical `Ingredient` sharing across recipes is intentional and must not
   be mistaken for line duplication.
4. The legacy screenshot shape is representable as three distinct persistent
   line objects, or as one object repeated in an inverse array; both shapes
   are covered by the auditor's evidence model and the test snapshot helper.

Not verified without the affected store:

* whether the reported users have three distinct line UUIDs, repeated inverse
  references, parser output triples, or only a stale relationship cache;
* whether CloudKit redelivery or concurrent devices created new UUIDs in the
  affected database;
* whether archive/legacy migration is the historical origin;
* whether a specific old matcher/cleanup decision caused the unrelated
  canonical name or the quantity/dimension mismatch.

## Test execution

Passed on the iOS 27 simulator (iPhone 18 Pro):

```text
xcodebuild test -project MealPlan.xcodeproj -scheme MealPlan \
  -destination 'platform=iOS Simulator,id=A7365E70-AC92-4325-88F7-C7549894BB57' \
  -only-testing:MealPlanTests/IngredientCorruptionRegressionTests \
  -only-testing:MealPlanTests/IngredientIntegrityAuditorTests \
  -only-testing:MealPlanTests/IngredientCleanupTests
```

Result: **passed** (27 tests in 3 suites). A focused CloudKit/replay run also
passed the disk-backed repeated/out-of-order line, stale tombstone, targeted
deletion, and newest-record deduplication cases. A broad parallel sync-suite
run exposed an unrelated existing test-store concurrency flake; the new
context-scoped lookup cache and the focused CloudKit cases pass. The normal
simulator build completed as part of these test runs.

The fixture file is automatically included by the project's synchronized
`MealPlanTests` group; no project-file membership edit was needed.
