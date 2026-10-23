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

## Release gates still open

- Make household replacement, rejoin, and confirmed revocation lossless and
  restart-safe. Never delete the only local copy of plans, shopping state,
  history, routines, or offline edits.
- Verify CloudKitCollaborationKit remains the only engine owner per account,
  environment, and database scope. Keep SwiftData mirroring disabled.
- Audit write permissions across the app, widgets, Share Extension, App
  Intents, and Watch pathways.
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
