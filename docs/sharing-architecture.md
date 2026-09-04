# Per-record household sharing architecture

Status: **proposal — approval required before migration code is written**

This plan replaces the whole-household `MealPlanBackup` asset transport with
one CloudKit record per entity, driven by `CKSyncEngine`. It deliberately does
not change `HouseholdCloudSharingService` yet. The existing blob remains the
authoritative sharing path until the migration reaches its explicit cutover.

## Decision: one CloudKit owner

At cutover, household-scoped SwiftData models will stop using SwiftData's
`.private` CloudKit mirroring. `SharedStore` will open the App Group store with
`cloudKitDatabase: .none`, and `CKSyncEngine` will be the only CloudKit writer
for those models.

Running both systems against the same logical data would create two independent
change streams, two conflict policies, and duplicate uploads. A shadow phase is
safe only because it is outbound-only, uses MealPlan-owned record types in a
separate custom zone, and never applies shadow records to SwiftData. It is an
instrumented export, not a second sync path.

The cost is real: each device performs one full per-record upload/download at
cutover. We also take ownership of schema evolution, retry visibility, and
change application that SwiftData mirroring handled quietly. The benefit is
that solo multi-device sync and shared-household sync use the same record
encoder, conflict rules, tombstones, and tests.

## Databases, zones, and shares

Each household has exactly one custom zone named
`MealPlanHousehold-<household UUID>`.

- A solo household's zone is in its owner's private database.
- The first share creates a zone-wide `CKShare` for that existing zone. The
  records do not get copied or assigned new IDs. On the owner device the zone
  remains addressed through the private database; accepted participants see
  the same zone through the shared database.
- The local household UUID is the durable identity across private, shared,
  blob, backup, invitation, and rollback paths. Accepting a share upserts that
  UUID; it never creates a second local household with another UUID.
- `CKSyncEngine` state serialization is stored per database scope and zone in
  the App Group. Owner-private and participant-shared tokens can therefore
  never be interchanged.

The `Household` record is the logical root and carries the current schema and
migration generation. Owned child records also carry a `.deleteSelf` reference
to the root where CloudKit permits it, but relationship resolution uses stable
UUID fields rather than save-order-sensitive record references.

## Record schema

Record names are stable UUID strings. Every record has `householdID`,
`schemaVersion`, `modifiedAt`, and `modifiedByParticipantID`. Optional values
are removed from a `CKRecord`, not represented by sentinels. Relationships are
UUID strings or UUID arrays. Large binary data is never placed in another
entity's record.

| Record type | Identity and important fields | Conflict family |
| --- | --- | --- |
| `MPHousehold` | household UUID; name, units, portions, nutrition preferences, seed flags | last writer wins |
| `MPHouseholdMember` | new stable UUID plus CloudKit participant identity; role, display name, active/removed state | participant reconciliation |
| `MPMealType` | existing UUID; key, name, symbol, ordering | last writer wins |
| `MPDish` | existing UUID; recipe, source, variants, labels, servings, times, nutrition, glyph and usage metadata | last writer wins |
| `MPDishIngredient` | **new UUID**; dish UUID, ingredient UUID, amount/unit/note/order | last writer wins |
| `MPDishImage` | **new UUID**; dish UUID, order, primary flag, added date | metadata last writer wins; bytes in asset record |
| `MPDishImageAsset` | image UUID; `CKAsset` only, content hash | immutable by hash; replacement creates a new asset version |
| `MPIngredient` | **new UUID** while retaining normalized name; aisle, pantry and nutrition fields | UUID last writer wins; migration deduplicates normalized names |
| `MPMealPlanEntry` | existing UUID; placement fields, content fields and their clocks | grouped field merge |
| `MPMealRoutine` | existing UUID; dish, meal, cadence, dates and active state | last writer wins |
| `MPCookedLog` | existing UUID; date, dish/name snapshot and servings | last writer wins |
| `MPCookedLogImageAsset` | cooked-log UUID; `CKAsset` and content hash | immutable by hash |
| `MPShoppingListItem` | existing UUID; item details plus independent check-state clock | grouped field merge |
| `MPWeekTemplate` | existing UUID; name, creator and date | last writer wins |
| `MPWeekTemplateEntry` | **new UUID**; template, weekday, meal, dish, servings and order | last writer wins |
| `MPRecipeFeed` | existing UUID; site/feed URL, validators and health metadata | last writer wins |
| `MPRecipeFeedItem` | existing UUID; feed UUID and article metadata, never body HTML | last writer wins |
| `MPRecipeBookmark` | existing UUID; title, URL and date | last writer wins |
| `MPDeletionMarker` | `<record type>:<entity UUID>`; deletion time, participant and prior change tag | deletion wins over stale writes |

The first model migration adds `uuid` and `modifiedAt` defaults to models that
lack them, plus the two grouped conflict clocks below. New IDs are assigned
once and persisted before any upload. The migration's mapping table is saved
with the backup so rollback restores the same identities.

Article HTML from recipe discovery remains in `RecipeArticleCache`; it is not a
record field, backup field, or `CKAsset`.

## Deletes and tombstones

A local delete performs two durable actions in one SwiftData save transaction:

1. append a local pending deletion containing record ID, entity type,
   `deletedAt`, and the last known server change tag;
2. remove the user-facing model.

The engine sends a CloudKit record deletion and saves an `MPDeletionMarker`.
The marker is retained after the deleted record disappears. A peer proposing
an older edit compares its `modifiedAt` with the marker and drops the edit,
then deletes its stale local row. A later intentional recreation receives a
new UUID, so it does not fight the marker.

Pending deletions are cleared only after CKSyncEngine acknowledges both the
record deletion and marker save. Markers are compact and retained for the
compatibility window plus the maximum supported offline interval; the initial
implementation keeps them indefinitely. A future garbage collector may remove
them only after participant acknowledgements exist, never merely because a
wall-clock interval passed.

## Conflict rules

CloudKit's server record is the serialization point. On
`serverRecordChanged`, the client decodes the server record, applies the rule
for that record type, and resubmits only when its merged value differs.

### Default: per-record last writer wins

Most records compare model `modifiedAt`. The newer record wins as a whole. A
tie uses CloudKit's server `modificationDate`, then the lexical participant ID
for deterministic tests. Device clocks remain visible in diagnostics; dates
implausibly far in the future are clamped to the receive time so one bad clock
cannot own a record forever.

This means two people editing different dishes never conflict. Two people
editing the same dish get an explicit, deterministic last-writer result instead
of whichever whole-household backup happened to export last.

### Shopping list

Different shopping rows are already different records, so checking milk cannot
overwrite checking bread. Within one `MPShoppingListItem`, content fields use
`contentModifiedAt` and `isChecked` uses `checkStateModifiedAt`. Merge takes the
newer value in each group. Thus a quantity edit and a check/uncheck in the same
window both survive. For equal check clocks, `true` wins, which avoids an
offline unchecked snapshot undoing a confirmed check; an intentional uncheck
gets a new clock and still wins normally.

Generated-list rebuilds upsert stable item UUIDs by normalized ingredient and
range rather than deleting and recreating rows. Manual rows retain their UUID.

### Meal plan entries

`date`, `mealKey`, and `sortIndex` form the placement group with
`placementModifiedAt`. Dish, servings, note, reminder, reaction, skip/eating-out
details, and attribution form the content group with `contentModifiedAt`.
Merging independently by group preserves a move on one device and a note or
serving edit on another. Deletion markers still beat either group when the edit
predates deletion.

## Change capture and live updates

All app write paths call a small shared mutation helper that updates the proper
clock and records the dirty entity ID. A ModelContext save observer is a safety
net for older/direct call sites; it compares compact local fingerprints to the
last synced snapshot and queues anything the helper missed.

Sync is requested:

- on app foreground;
- after local saves, debounced into one request;
- when the app delegate receives the CloudKit push for the database/zone; and
- explicitly after accepting a share or completing migration.

CKSyncEngine owns tokens, batching, partial failures, account changes, and
retry timing. Push is a prompt to fetch changes, not the payload itself. Every
inbound batch is applied in one ModelContext transaction, then widgets are
reloaded and `.mealPlanDataDidChange` is posted.

## Role enforcement and member reconciliation

The share is authoritative for role. Before emitting changes, the engine reads
the current participant permission cached from the latest `CKShare`:

- owners and `.readWrite` participants may enqueue writes;
- `.readOnly` participants never enqueue a save or delete;
- CloudKit permissions remain the final enforcement boundary and reject a
  forged or stale client write.

`HouseholdWriteGate` is used by the app and share extension. If a read-only
participant changes the local App Group store through an old or missed UI path,
the save observer quarantines that local delta, restores the last server value,
and presents a localized explanation on next foreground. It is not allowed to
remain as an unsynced apparent edit.

`HouseholdMember` gains stable UUID, `cloudKitParticipantID`, and `isActive`.
Refreshing a share upserts by participant identity, changes role/name in place,
and marks removed participants inactive. It never delete-and-recreates the
list, so member-linked local state can survive. The current participant is
reconciled too; `isCurrentUser` is a local projection, not shared truth.

## Share extension and widgets

The extension and widgets continue opening the App Group SwiftData store with
CloudKit disabled. They do not instantiate CKSyncEngine:

- The share extension writes imported models locally through
  `HouseholdWriteGate` and appends their IDs to an App Group dirty journal. The
  main app drains it and syncs on its next foreground. A read-only participant
  is rejected before import.
- Widgets are read-only. They see inbound changes after the main app applies a
  batch and calls `WidgetCenter.reloadAllTimelines()`.
- Both compile the same shared model/schema and therefore understand UUIDs and
  clocks. Neither owns tokens or performs network work.

This preserves quick extension completion and avoids two processes mutating the
same CKSyncEngine state concurrently.

## Migration state machine

Migration is per household and monotonic, with state persisted both locally
and in an `MPHouseholdMigration` CloudKit record:

`notStarted → backupWritten → IDsAssigned → shadowUploaded → shadowVerified → cutoverReady → cutoverComplete`

Each transition is idempotent. Re-entering a completed transition verifies its
artifacts and advances; it never repeats destructive work. The local record
stores the backup URL/checksum, household UUID, source blob locator if any,
target zone, schema version, record counts/hashes, and last error.

Before any model or store configuration change, the app writes an atomic,
photo-inclusive `MealPlanBackup` into an App Group `MigrationBackups` directory
and verifies it can be decoded. The backup is not deleted automatically.

### Existing solo household

1. Keep SwiftData private mirroring authoritative.
2. Assign missing IDs/clocks once and shadow-upload to the household custom
   private zone. Do not apply downloads.
3. Compare per-type counts and canonical hashes with the local store.
4. When the flag and migration record both say `cutoverReady`, close the
   container, reopen the same App Group store with CloudKit `.none`, and make
   CKSyncEngine authoritative.
5. Fetch changes, reconcile by stable UUID, verify again, then mark complete.

Every other device signed into that iCloud account downloads the same zone and
reconciles its local store from scratch once. Duplicate local households are
folded by UUID before records are applied.

### Existing blob-shared household

The blob cannot be discarded before every participant has a record path.

1. Owner and participants first run the current blob merge, write/verify their
   local migration backup, and pin the blob household UUID as the target.
2. The owner creates the new zone-wide share and record set, then writes an
   `upgradeAvailable` marker (household UUID, generation, and share metadata)
   to the legacy blob root. The blob remains authoritative.
3. Existing CloudKit participants are reconciled by identity. Where CloudKit
   requires a new acceptance, the owner sends the new invitation and the old
   client continues on the blob meanwhile; MealPlan never silently invents a
   second household.
4. A participant accepting the new share matches the existing local household
   UUID, shadow-downloads records, verifies them against the last blob merge,
   and records an acknowledgement in the new zone.
5. The owner cuts over only after all currently accepted participants either
   acknowledge or are explicitly removed. During the compatibility window,
   new versions dual-publish a compact legacy blob after successful record
   sync so an old app can still be brought forward. New versions never merge a
   legacy blob after their own `cutoverComplete` generation.
6. After the compatibility window, the owner marks the blob retired. Its share
   and asset are deleted only in a later release.

This flow may require an old participant to accept one upgrade invitation, but
it does not lose their offline edits: the final pre-cutover blob merge happens
before their acknowledgement, and all records retain the original household
and entity UUIDs.

### First share after record-sync cutover

The solo custom zone is already complete. The app creates its zone-wide
`CKShare`, configures participant permission, returns the invitation URL, and
continues using the same zone. Acceptance opens the shared database, upserts
the household UUID, performs a full fetch, and only then exposes the household
in the UI.

## Rollback and failure behavior

Before `cutoverComplete`, rollback is automatic and non-destructive:

- leave SwiftData mirroring and/or the blob path authoritative;
- stop the shadow engine;
- retain the custom zone for diagnostics or delete it only after hash-verified
  re-export is possible;
- restore the verified migration backup if ID assignment or local application
  changed the store; and
- reset the state only to the last verified transition, never to `notStarted`.

After local cutover but before cloud verification, the app closes the `.none`
container, restores the backup into a fresh local store, and reopens the legacy
configuration. It does not merge partially downloaded records into the
restored store. A rollback marker prevents the same build from immediately
retrying; the user keeps local functionality and sees a plain-language status.

After `cutoverComplete`, the old mirror is not re-enabled automatically because
that would recreate the dual-writer hazard. Recovery exports a backup, rebuilds
the local store from the per-record zone, and escalates a corrupt zone for an
explicit user choice.

## Delivery phases and flags

### Phase 1 — private shadow engine

- Implement record codecs, dirty journal, engine state persistence, tombstones,
  and conflict functions behind `recordSyncShadowEnabled`.
- Upload to a private custom zone only. Blob/SwiftData mirroring stays live and
  authoritative; no shadow download mutates models.
- Ship schema/count/hash diagnostics and pure codec/conflict tests.

### Phase 2 — guarded migration and private cutover

- Add UUIDs/clocks through a SwiftData migration plan.
- Write and verify a full backup first.
- Exercise the idempotent state machine and switch solo households from
  SwiftData mirroring to private CKSyncEngine only after shadow verification.
- Roll out with a local kill switch that can stop sync without changing the
  store configuration.

### Phase 3 — shared database

- Add zone-wide CKShare creation, invitation, acceptance, push routing,
  participant reconciliation, and read-only enforcement.
- Migrate existing blob-shared households using acknowledgements and the same
  household UUID.

### Phase 4 — blob retirement

- Maintain dual-published compatibility blobs for the stated support window.
- Stop reading blobs after the household's cutover generation.
- Retire UI and code paths only after old-participant upgrade metrics can be
  inspected locally by the owner and an export remains available.

No flag permits two inbound authorities. Flags select `legacy authoritative`,
`record shadow outbound`, or `record authoritative` as mutually exclusive
states.

## Required tests and acceptance checks

Pure tests use in-memory records/snapshots and a fake engine adapter; CloudKit
integration checks run in a development container on two physical accounts.

1. Devices A and B edit different dishes offline, reconnect in either order,
   and both edits appear without extra dishes.
2. Both edit the same dish; the later `modifiedAt` record wins identically on
   both devices, including deterministic tie behavior.
3. A deletes while B edits offline; an edit older than the deletion cannot
   resurrect the row. Recreating it produces a new UUID.
4. A device stays offline for seven days, crosses several change batches, and
   converges after reconnect without a full duplicate upload.
5. Two people check different shopping items and both checks survive; a
   quantity edit and check on the same item also both survive.
6. One device moves a meal while another edits its note/servings and both field
   groups survive.
7. A read-only guest attempts create, edit, and delete from the app and share
   extension; the local store is restored and CloudKit receives no accepted
   mutation.
8. Removing a participant revokes later writes, marks its member inactive, and
   preserves state attached to that member.
9. Each migration transition is interrupted and relaunched; it resumes once,
   preserves IDs, and never overwrites its verified backup.
10. An already blob-shared household upgrades without creating another local
    household, including one participant offline during the compatibility
    window.
11. Widgets reflect an inbound plan change after the app handles a push; the
    share extension's dirty journal uploads on the next app foreground.
12. Asset tests prove that changing a dish name does not upload image bytes.

Release acceptance additionally requires iOS and macOS builds with no new
warnings, a restore drill from the pre-migration backup, and a recorded hash
match for every entity type before the authoritative flag changes.
