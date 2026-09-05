# Recipe translation

A household's recipes arrive in whatever language they were written in — a
scanned German cookbook, a Spanish blog, a friend's export. The cook, meanwhile,
reads whatever language their device is set to. Translation closes that gap
without taking the original away.

## Where it runs

`RecipeTranslator` asks Apple Intelligence's on-device model, the same way
`RecipeExtractor` already reads scanned pages. Nothing leaves the device, which
matters twice over: a recipe collection is personal, and a translated recipe is
still there in a kitchen with no signal. Where the model isn't available —
an ineligible device, Apple Intelligence switched off, the model still
downloading — the sheet says which of those it is and offers nothing else.
There is no cloud fallback.

Text goes out in small batches (`RecipeTranslationBatcher`), one numbered entry
per line of the recipe, and comes back the same shape. That is what keeps a
recipe a recipe: the model can't re-flow a step list into prose, a long recipe
can't run past the context window, and a batch that comes back with the wrong
number of entries is discarded rather than paired up with the wrong
ingredients. A batch that fails twice keeps its original wording, so a partial
translation is always readable rather than half-missing.

## Beside the recipe, not over it

A translation is stored next to the recipe:

- `Dish.translationLanguageCode`, `translatedName`, `translatedRecipeText`
- `DishIngredient.translatedName`, `translatedNote`
- `Dish.recipeLanguageCode` records what the recipe itself reads as

The recipe's own wording is what the cook imported or typed, and a household
that reads in two languages needs both. So `Dish.displayName(translated:)` and
its siblings pick a wording per screen, and every view that shows one offers a
switch to the other. A recipe opens translated only when the saved translation
matches the language *this* device reads (`Dish.prefersTranslation`) — the
member who saved a German translation gets German, the one on an English device
still opens the recipe as it was written.

Editing the recipe drops the translation (`DishEditorView.save` compares
`translationSourceSignature` from before the edit). A translation that no longer
describes the recipe in front of you is worse in a kitchen than none at all.

## What is deliberately *not* translated

The shared `Ingredient` catalogue keeps its original names. It is what the
shopping list matches, aggregates and syncs to Bring! on, and what pantry
staples are recognised by; translating it would split a household's onions into
two entries and quietly change what lands on the list. Translation is a
property of a recipe line, not of the ingredient itself, so the shopping list
stays in the household's own vocabulary.

## What travels

Translations sync between household devices (`HouseholdRecordCodec`) and are
kept by backup and restore, since they are part of that household's own data.
They are *not* part of the shareable `.mealplanrecipes` archive: that file is a
recipe passed to someone else, whose device translates into their own language
if they want it.
