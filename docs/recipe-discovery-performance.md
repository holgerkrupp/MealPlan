# Discover recipes performance notes

Issue #24 adds signposts in the `recipe discovery` category for four intervals:

- `discovery snapshot` — value snapshot construction and filtering.
- `article image lookup` — bounded article-page lookup.
- `thumbnail load` — bounded remote image download.
- `article navigation` — reader task from destination appearance through the initial page load.

Use the Time Profiler and SwiftUI template in Instruments while continuously
scrolling a populated Discover grid on a physical iPhone and iPad. Filter by
the `de.holgerkrupp.mealplan` subsystem and the `recipe discovery` category.
Record scroll hitching, main-thread time, signpost durations, request counts,
peak memory after repeated up/down scrolling, and tap-to-reader appearance.

The repository does not include physical devices, an Instruments trace, or a
representative populated household in CI, so this checkout cannot establish
device-specific baseline numbers. The code now exposes the required intervals
and bounds the two network paths so those measurements can be added to the PR
from the target devices without changing the implementation.

## Implementation guardrails

`RecipeDiscoverySnapshot` is built from Sendable value seeds outside SwiftUI
body evaluation. It deduplicates URLs, computes categories with one membership
set, groups mixed sources in one pass, and applies the 40/80 result limit.
Read state is read once per snapshot and stored on the card value.

Article-page lookups are limited to three concurrent requests, coalesced by
article URL, cancellation-aware while queued, and cache `.none` for the
session. Remote thumbnails use a separate three-request gate, URL cache,
request coalescing, and bounded compressed-byte memory. Tasks check cancellation
before publishing back into a card.
