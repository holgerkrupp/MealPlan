# Per-record household sharing architecture

Status: **managed-sharing migration is staged behind a per-household cutover gate**

For how the shipped implementation works — both across one account's
devices and between different people — see
[`icloud-sharing.md`](icloud-sharing.md).

The shipped MealPlan store is SwiftData with one CloudKit record per entity,
driven by `CKSyncEngine`. That path remains the only active writer until an
owner's existing household has been staged and all dependent clients are ready
to move together. The sibling `CloudKitCollaborationKit` package supplies the
new Core Data sharing and invitation foundation. The app copies the existing
graph offline, keeps the SwiftData store intact, and does not enable CloudKit
mirroring or create a share during staging.

This is a preservation migration. Stable UUIDs, image bytes, relationships,
member metadata, and records from every supported SwiftData entity are copied
without semantic rematching. The new writer boundary is one way: once managed
writes are accepted, the app must never silently switch back to writable
SwiftData/`CKSyncEngine` state.

## Legacy writer retained during staging

The App Group SwiftData store is opened with `cloudKitDatabase: .none`.
`CKSyncEngine` is the only CloudKit writer, so there is one change stream and
one set of conflict rules for solo multi-device use and shared households.
Extensions and widgets continue to open the same local store without starting
their own engine.

## Databases, zones, and shares

Each household owns one custom zone named
`MealPlanHousehold-<household UUID>`.

- A solo household uses the owner's private database.
- Sharing creates a zone-wide `CKShare` for that existing zone; records are
  not copied or renamed.
- The owner keeps addressing the zone through the private database. Accepted
  participants address it through the shared database.
- CKSyncEngine state and local record metadata are stored per database scope,
  zone, and owner in the App Group defaults.
- A share invitation upserts the household by its durable UUID before the
  engine fetches its child records.

## Record schema

Every record name is `<record type>-<entity UUID>` and contains `householdID`,
`schemaVersion`, `modifiedAt`, and an encoded payload. Relationships use UUIDs
rather than save-order-sensitive references. `DishImage` and cooked-log image
bytes are separate records whose binary value is a `CKAsset`; recipe article
HTML remains only in the local reader cache.

The record types cover households, participants, meal types, dishes, dish
ingredients and images, ingredients, plan entries, routines, cooked logs and
images, shopping rows, week templates and entries, recipe feeds and items,
bookmarks, and deletion markers.

## Change capture and deletes

All syncable models have a stable UUID and `modifiedAt`. After a SwiftData
save, a debounced safety-net scan compares compact record fingerprints with
the last submitted snapshot. It advances the relevant conflict clock and
queues a CKSyncEngine save. This also catches writes from existing code paths
and the share extension without requiring every call site to know CloudKit.

When a previously known UUID disappears, the scan queues both its record
deletion and a persistent `MPDeletionMarker`. A stale peer that later receives
the marker removes its old row. Intentional recreation uses a new UUID.

Sync is requested after local saves, on foreground, when CloudKit wakes the app
with a push, after accepting a share, and by a low-frequency foreground retry.
CKSyncEngine owns tokens, batching, subscriptions, retries, and partial-error
delivery.

## Conflict policy

Most entities use per-record last-writer-wins based on `modifiedAt`. Therefore
editing two different dishes never conflicts.

Meal-plan entries use two clocks:

- placement: date, meal slot, and sort index;
- content: dish, portions, notes, reminders, reaction, skip/eating-out data,
  and attribution.

Shopping-list items also use two clocks:

- content: name, amount, aisle, source, and ordering;
- check state: checked or unchecked.

Those groups merge independently when CloudKit reports
`serverRecordChanged`, so moving a meal does not erase a simultaneous note and
editing an amount does not undo a check. Equal shopping check clocks prefer
checked; a later intentional uncheck still wins normally.

## Roles and members

The `CKShare` is authoritative. Owners and read-write participants may emit
changes; read-only participants never receive an outbound batch, and CloudKit
is the final enforcement boundary. Participant refreshes upsert
`HouseholdMember` by CloudKit participant ID, update names and roles in place,
and mark removed members inactive instead of recreating the list.

## Failure behavior

The local SwiftData store remains usable offline. Pending CKSyncEngine changes
and serialized state survive relaunch, and networking or quota failures remain
pending for the next foreground/save retry. Server conflicts are merged against
the returned system record and resubmitted with its change tag. Manual JSON
backup/restore remains available as the recovery path during development.

## Managed collaboration transition

The app links the `CollaborationCore`, `CollaborationCoreData`,
`CollaborationUI`, and `CollaborationDiagnostics` products from the sibling
`CloudKitCollaborationKit` package. The app adapter supplies its CloudKit
container, exact loaded private/shared store objects, a stable household root
resolver, and a background closed-graph preflight. The package stays generic;
MealPlan owns model mapping, schema markers, and migration decisions.

At launch, an owner with one unambiguous private SwiftData household stages a
copy into environment-scoped Core Data stores with CloudKit mirroring disabled.
The state marker is scoped by environment and household UUID. It records the
phase, per-entity identity inventory, batch checkpoints, and content digest.
The importer reuses stable UUIDs, copies image data, links relationships after
row creation, detects edits while copying, reconciles the offline destination,
and checks the copied attributes and ingredient-integrity findings. A failed
batch can resume; a changed authoritative source becomes a fresh stage. The
SwiftData store is never deleted or rewritten by this migration.

The durable rollout phases are `legacyActive`, `inventory`, `stagedCopy`,
`verified`, `readyForCutover`, `managedActive`, and `membersReinvited`, plus a
fail-closed recovery state. Verification alone cannot enable mirroring. The
readiness record requires a confirmed canonical owner, same-account
convergence, a stable legacy snapshot, resolved legacy writers, a migrated app
mutation path, migrated extensions/widgets, and owner confirmation. Activation
then performs a final serialized legacy sync and rechecks the durable record
before changing authority. After activation, the old sync engine never scans
or sends and extension/widget writes to the retired legacy path are rejected.

The migration and package adapter are staged for rollout; the SwiftData UI,
widgets, and Share Extension have not yet moved to managed Core Data. Therefore
the readiness gate remains closed in this version, and the new native sharing
and one-time re-invitation experience is not shown. Existing owner data and
legacy invitations continue to use the current path until those clients can
switch together. A production rollout still needs physical-device validation
with two Apple Accounts, offline/old-version devices, and CloudKit Development
and Production environments before the gate is enabled.
