# Native App Store review requests

MealPlan records a small, local-only engagement ledger for issue #157. A
successful direct placement is recorded only after `ModelContext.save()` has
completed, using the new `MealPlanEntry` UUID as the deduplication key. The
ledger contains counts, actual action timestamps, locale-aware calendar-week
keys, a bounded UUID ledger, and the last StoreKit request attempt; it never
contains recipe names, planned meal dates, or household records.

The eligibility policy requires ten distinct direct placements, three calendar
weeks according to the current calendar's week rules, and fourteen full days
between the first and latest qualifying action. Moves, edits, synchronization,
migrations, sample data, recipe imports, and routine/recurring/template/day
copy operations are excluded. The latter are intentionally conservative: one
bulk action cannot manufacture ten engagement events.

The JSON ledger lives in the existing App Group and uses a cross-process file
lock around each read/modify/write transaction, allowing the Share Extension
and App Intents to record successful placements safely. Only the foreground
main-app scene owns `RequestReviewAction`; extensions and background intents
never present StoreKit. The coordinator waits for an ordinary active scene,
checks known busy/modal states, records an attempt before calling StoreKit, and
limits attempts to one per app version with a 365-day cooldown. StoreKit may
still suppress the native dialog (including TestFlight), and this implementation
does not infer whether a dialog or review was displayed.

Deterministic policy, persistence, deduplication, failed-write, week-boundary,
restart, cooldown, and coordinator tests are in
`MealPlanTests/ReviewEligibilityPolicyTests.swift`. Physical-device StoreKit
behavior remains release validation work for issue #144.
