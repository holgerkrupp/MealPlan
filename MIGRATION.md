# Recipe migration notes

MealPlan accepts recipes through its existing URL importer, file importers, and
the share sheet. A migration list can contain one user-accessible recipe URL
per line; the generic import queue canonicalizes tracking parameters,
deduplicates URLs, imports off the main UI task, and keeps failures for review.

## Mealime

Mealime is used here only as a descriptive product name; MealPlan is not
affiliated with it. Before importing anything, the user should use only the
export or sharing options visible in their own Mealime account or the official
shutdown communications. Supported inputs are public/shareable recipe URLs
and files the user has legitimately exported. Private account scraping,
undocumented APIs, authentication bypasses, and bulk downloading from a
logged-in session are intentionally unsupported.

The importer preserves the source URL, title, image when publicly available,
instructions, servings, and ingredient text. Structured quantities are routed
through MealPlan's canonical ingredient parser. Pages without complete
structured data are marked for review; unsupported account metadata, meal
history, grocery orders, and private collections are not silently claimed to
be migrated.

For a temporary onboarding link, use wording such as **Moving from Mealime?**
and explain exactly which public URLs or exported files are supported. Do not
imply an integration or affiliation.
