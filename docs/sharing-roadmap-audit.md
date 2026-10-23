# Household sharing roadmap audit

Audit baseline: MealPlan `main` at `6cf85f065b169e429e5bb02c69114cd79848cd00` (2026-10-23).

## Target architecture

```text
SwiftUI features
→ SwiftData ModelContainer in the App Group
→ MealPlan record codec, mutation detection, and conflict handling
→ CloudKitCollaborationKit
→ private/shared CloudKit databases and the existing zone-wide CKShare
```

MealPlan has one authoritative local SwiftData store. `SharedStore` opens it
with `cloudKitDatabase: .none`; the app's `HouseholdRecordSyncService` adapts
MealPlan records to the package-owned `CloudKitSyncEnginePool`. The host codec,
applier, conflict policy, durable change journal, and tombstones remain
necessary because MealPlan owns the SwiftData schema. Widgets and the Share
Extension open the App Group store but do not create a sync engine.

The package pin at this audit baseline is
`860b0f3d5950a9129056c2056a00e21cb08827b0`. The Core Data files under
`MealPlanShared/Persistence/ManagedHousehold*` have no production call sites;
they are referenced by their own tests. They are dormant migration scaffolding,
not active persistence. Keep them until their recovery value and test/build
dependencies have been deliberately reviewed.

## Issue status against the current implementation

“Verified” here means supported by source and automated tests at the audit
baseline. It does not mean verified against Production CloudKit on signed
devices.

| Issue | Audit status | Evidence and remaining work |
| --- | --- | --- |
| [#81](https://github.com/holgerkrupp/MealPlan/issues/81) | Superseded by the SwiftData decision | Managed-store foundation and tests exist, but no production call sites use it. Keep as historical implementation evidence; do not activate it. |
| [#82](https://github.com/holgerkrupp/MealPlan/issues/82) | Superseded by the SwiftData decision | SwiftData remains canonical; a SwiftData-to-Core-Data migration is not part of this rollout. |
| [#83](https://github.com/holgerkrupp/MealPlan/issues/83) | Superseded by the SwiftData decision | Managed-store adoption/canonicalization is obsolete. Same-account discovery and recovery remain part of the SwiftData flow and require device evidence. |
| [#84](https://github.com/holgerkrupp/MealPlan/issues/84) | Implemented but insufficiently tested | The package supplies share lifecycle, existing-share lookup, participant state, and native UI. Preserve existing share identity; verify permissions, retries, and both platform paths on signed devices. |
| [#85](https://github.com/holgerkrupp/MealPlan/issues/85) | Partially implemented | Package invitation acceptance is wired to the SwiftData root callback and duplicate delivery is queued/deduplicated. Household replacement can discard non-recipe local data and must become lossless/restart-safe before release. |
| [#86](https://github.com/holgerkrupp/MealPlan/issues/86) | Superseded by the SwiftData decision | Re-invitation is not the default: reuse healthy zone-wide shares and participant identities. New invitations are only a verified fallback. |
| [#87](https://github.com/holgerkrupp/MealPlan/issues/87) | Superseded by the SwiftData decision | Feature/UI cutover to Core Data is explicitly out of scope; features continue to use SwiftData. |
| [#88](https://github.com/holgerkrupp/MealPlan/issues/88) | Partially implemented | Extensions and widgets use the App Group SwiftData store and do not own the CloudKit engine. Read-only enforcement and exactly-once cross-process mutation capture still need an entry-point audit. |
| [#89](https://github.com/holgerkrupp/MealPlan/issues/89) | Superseded by the SwiftData decision | The package owns sync-engine instances, while the MealPlan host adapter remains active and necessary. Do not remove the record codec, applier, conflict resolver, or tombstones. |
| [#90](https://github.com/holgerkrupp/MealPlan/issues/90) | Partially implemented | Unit coverage exists for codecs, conflicts, recovery, and state migration. No signed two-account Production device evidence is recorded. |
| [#114](https://github.com/holgerkrupp/MealPlan/issues/114) | Partially implemented | Package integration is in place, but the original Core Data/re-invitation plan is obsolete. Keep the epic open for join recovery, permission audit, and physical-device release gates. |
| [#115](https://github.com/holgerkrupp/MealPlan/issues/115) | Implemented but insufficiently tested | Package products and host adapters are wired against the existing SwiftData graph. Confirmed by source and package pin; signed CloudKit verification remains. |
| [#116](https://github.com/holgerkrupp/MealPlan/issues/116) | Superseded by the SwiftData decision | The re-invitation onboarding requirement conflicts with reusing healthy existing shares. Use the native package UI and only request a new invitation when a verified incompatibility requires one. |
| [#117](https://github.com/holgerkrupp/MealPlan/issues/117) | Superseded by the SwiftData decision | Owner cutover to a new Core Data store is not planned. Offline edits and staged recovery remain required within the existing SwiftData transport. |

## Implementation merged after the audit baseline (2026-10-23)

These focused PRs have since been merged into `main`:

- [#126](https://github.com/holgerkrupp/MealPlan/pull/126) — owner share management and invitation sync behavior.
- [#127](https://github.com/holgerkrupp/MealPlan/pull/127) — durable state/journal migration, scoped recovery cleanup, and sync apply-error visibility.
- [#128](https://github.com/holgerkrupp/MealPlan/pull/128) — architecture and roadmap documentation.
- [#129](https://github.com/holgerkrupp/MealPlan/pull/129) — lossless local join/recovery archives, accepted-root verification, and source-transport rollback.
- [#130](https://github.com/holgerkrupp/MealPlan/pull/130) — Watch/widget write authorization and mutation signaling.

Combined focused macOS coverage passed 33/33 tests; focused iOS Simulator
authorization coverage passed 4/4 tests; and the combined iOS Simulator
`build-for-testing` succeeded. These results verify code and simulator behavior,
not Production CloudKit collaboration. GitHub Actions returned no PR workflow
runs. The signed-device matrix below remains unrun, as do representative
CPU/energy measurements and immediate cross-process wakeup/convergence tests.

## Release gates still open

- Verify the merged household replacement, rejoin, and confirmed-revocation
  recovery flows on signed devices and after interruption. Confirm that plans,
  shopping state, history, routines, preferences, and offline edits remain
  recoverable.
- Verify CloudKitCollaborationKit remains the only engine owner per account,
  environment, and database scope. Keep SwiftData mirroring disabled.
- Finish device verification of effective write permissions across the app,
  widgets, Share Extension, App Intents, and Watch pathways.
- Complete the signed-device two-account Production matrix in issue #90. Unit
  tests and a presented share sheet do not prove Production collaboration.
- Record explicit pass/fail results for upgrade compatibility, existing-share
  preservation, duplicate/expired invitations, permissions, offline conflict,
  revocation versus transient failure, interruption, and Development versus
  Production isolation.
- Profile sync cost with representative small and large households; do not
  change from fingerprint capture to SwiftData history without parity,
  durable-cursor recovery, and performance evidence.

No claim of Production sharing completion is made by this audit.

## Signed-device Production test matrix

Run with a TestFlight or equivalently signed build using the Production
CloudKit environment, two different Apple Accounts, and physical iOS/iPadOS
and macOS devices. Attach build numbers, device/OS versions, account roles,
steps, logs with private identifiers removed, and observed results for every
case. Unit and simulator tests do not satisfy these cases.

| # | Scenario | Result | Evidence / notes |
| --- | --- | --- | --- |
| 1 | Owner on iPhone; participant on another iPhone | Not run | Requires two Production accounts and devices. |
| 2 | Owner on iPhone and Mac using the same Apple Account | Not run | Verify private-database household adoption and convergence. |
| 3 | Existing shared household before updating either device | Not run | Capture existing zone, record, and share identity before upgrade. |
| 4 | Owner updated first; participant remains on the older published version | Not run | Verify forward/backward compatibility during staged rollout. |
| 5 | Participant updated first; owner remains on the older published version | Not run | Verify forward/backward compatibility during staged rollout. |
| 6 | Both devices updated | Not run | Verify household records converge after both upgrades. |
| 7 | New, accepted, duplicate-delivery, and expired invitations | Not run | Record each invitation state and retry outcome. |
| 8 | Existing share and member survive upgrade without re-invitation | Not run | Verify stable CKShare identity and participant access. |
| 9 | Owner opens their own share link on another device | Not run | Verify private-database adoption rather than shared-database acceptance. |
| 10 | Owner, editor, and view-only permissions; role changes | Not run | Check app, widget, Share Extension, App Intents, and Watch writes. |
| 11 | Offline edits on both sides followed by reconnection | Not run | Include edits to shared and local-only data. |
| 12 | Simultaneous recipe, meal-position, and shopping-check changes | Not run | Record conflict outcome and duplicate-write behavior. |
| 13 | Share removal, confirmed revocation, and temporary CloudKit failure | Not run | Confirm only authoritative revocation enters recovery. |
| 14 | Interrupted sync, app termination, and device restart | Not run | Verify state, journal, deletions, assets, and retry recovery. |
| 15 | Large household with many recipes, images, and historical entries | Not run | Record sync duration, CPU, memory, and battery/energy impact. |
| 16 | Development versus Production state isolation | Not run | Verify no metadata, state, or share crosses environments. |
| 17 | Source household preserved when a join is canceled or fails | Not run | Verify all records and images remain recoverable after restart. |
