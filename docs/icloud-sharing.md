# How iCloud sharing is implemented

MealPlan keeps one household in step across every device that may see it.
That covers two situations which look the same to the people using the app
and are very different underneath:

- **Your own devices.** An iPhone, iPad, and Mac signed in to the same Apple
  Account all show the same plan. Nothing is "shared" in CloudKit's sense —
  every device reads and writes the owner's *private* database.
- **Other people.** A partner, a flatmate, or a grandparent joins the
  household from an invitation link. Their device reads and writes the same
  records through CloudKit's *shared* database, at the permission the owner
  granted.

Both run on the same transport, the same record format, and the same conflict
rules. Only the database scope and a few permission checks differ. This
document describes what the code does; [`sharing-architecture.md`](sharing-architecture.md)
records the design decisions that led there.

## The pieces

| File | Responsibility |
| --- | --- |
| `MealPlanShared/Support/SharedModelContainer.swift` | Opens the one App Group SwiftData store, deliberately with `cloudKitDatabase: .none`. |
| `MealPlanShared/Support/HouseholdRecordSyncService.swift` | The only CloudKit writer. Owns `CKSyncEngine`, the local change scan, and the share locator. |
| `MealPlanShared/Support/HouseholdRecordCodec.swift` | Turns the object graph into flat, per-entity records and back; also the snapshot model actor. |
| `MealPlanShared/Support/HouseholdRecordApplier.swift` | Applies a decoded record into the local store (upsert or delete). |
| `MealPlanShared/Support/HouseholdRecordConflictResolver.swift` | Decides what wins when the same record changed in two places. |
| `MealPlanShared/Support/HouseholdCloudBootstrapService.swift` | Finds and downloads a household this Apple Account already owns. |
| `MealPlanShared/Support/HouseholdCloudSharingService.swift` | Creates, replaces, and accepts invitations; keeps the member roster. |
| `MealPlan/Features/Household/CloudSharingView.swift` | The invitation sheet: access picker, link, QR code, re-issue. |
| `MealPlan/App/MealPlanApp.swift` | App and scene delegates: push registration and invitation delivery. |
| `MealPlan/App/RootView.swift` | Accepts queued invitations, warns before replacing a household, drives sync. |

Configuration that has to be right for any of this to work: the iCloud
container `iCloud.de.holgerkrupp.mealplan` and the App Group
`group.de.holgerkrupp.mealplan` in `MealPlan.entitlements`, `CKSharingSupported`
in `MealPlan/Info.plist`, and the `remote-notification fetch` background modes
set through `INFOPLIST_KEY_UIBackgroundModes` in the project file.

## The shared foundation

### One local store, one CloudKit writer

Every process — app, share extension, widgets — opens the same SQLite file in
the App Group container. SwiftData's own CloudKit mirroring is switched off
(`cloudKitDatabase: .none`) because it can only address the private database
and would create a second, competing conflict path for the same models. The
extension and the widgets never start a sync engine; they just write locally
and let the main app notice.

`HouseholdRecordSyncService` is that main app's single `CKSyncEngine`. It is
configured with `automaticallySync = false` and every fetch and send is queued
behind the previous one in `performCloudOperation`, because overlapping
explicit engine operations trip CloudKit's internal assertion.

### One zone per household

A household lives in a custom zone named `MealPlanHousehold-<household UUID>`.
`HouseholdShareLocator` is the small value that says where the app should talk
to it, and it is stored base64-encoded in `Household.cloudKitShareIdentifier`:

```
zoneName, ownerName, shareRecordName?, isOwner, isReadOnly
```

`isOwner` picks the database — private for the owner, shared for a
participant. Because the zone name carries the household UUID, any device can
recover the household's identity from a zone ID alone, which is what makes
both the multi-device discovery and older share links work without a CloudKit
query index.

### Flat records, stable names

`HouseholdRecordCodec` writes one CloudKit record per entity, named
`<record type>-<entity UUID>` (for example
`MPDish-1C0F…`). Each record carries `householdID`, `schemaVersion`,
`modifiedAt`, and an encoded `payload`; photos travel as a `CKAsset` on their
own `MPDishImage` / `MPCookedLogImage` record. Relationships are stored as
UUIDs, never as CloudKit references, so records can arrive in any order —
`HouseholdRecordType.applyPriority` still sorts them into a sensible apply
order (household first, then top-level entities, then their children, then
images, then deletion markers).

### Noticing local changes

Nothing in the feature code has to know about CloudKit. The service observes
`ModelContext.didSave` and schedules a scan five seconds later (debounced, so
a burst of edits costs one scan, and the expensive work stays out of the
frame that follows a tap):

1. `HouseholdSnapshotActor` — a `@ModelActor` on its own executor — serializes
   the household into value-type snapshots off the main actor.
2. Each snapshot's fingerprint (SHA-256 of payload plus photo hash) is compared
   with the fingerprint stored from the last successful submission.
3. Changed records get their conflict clocks advanced and are queued as
   `saveRecord`.
4. A record name that was known before and is now gone becomes both a
   `deleteRecord` and a new persistent `MPDeletionMarker`, so a device that was
   offline at the time still learns about the deletion later.

Fingerprints, per-group fingerprints, encoded system fields, and the tombstone
list are persisted in the App Group defaults, keyed by CloudKit environment,
database scope, zone name, and owner (`storageSuffix`). Development and
Production records are completely separate on the server, so their local sync
state must never share a key either.

A sync round happens on launch and whenever the active household changes
(`RootView.synchronizeHousehold`), after a debounced local scan, when CloudKit
sends a push, and right before and after an invitation is created or accepted.

### Resolving conflicts

`HouseholdRecordConflictResolver` runs both on fetched records and on a
`serverRecordChanged` rejection, where the merged result is resubmitted with
the server's change tag.

- Most entities: last writer wins on `modifiedAt`. Editing two different
  dishes on two devices therefore never conflicts.
- Meal plan entries carry two clocks — *placement* (date, slot, sort index)
  and *content* (dish, portions, notes, reminders, reaction, attribution) —
  and merge independently, so moving a meal on one phone does not erase a note
  typed on another.
- Shopping items likewise split *content* (name, amount, aisle, order) from
  *check state*. Equal check clocks prefer "checked"; a later deliberate
  uncheck still wins normally.
- Photos are never cleared by a missing asset. A photo is removed by deleting
  its record, and an image record whose server asset went missing is repaired
  from the local bytes.

## Sharing between your own devices

This path involves no `CKShare` at all.

**First device.** `AppState.bootstrap` creates the single `Household`. The
first sync adds the zone to the private database and uploads every record.

**A second device signed in to the same account.** Before creating a local
household, `AppState.bootstrapFromCloud` asks
`HouseholdCloudBootstrapService.restoreOwnedHouseholdIfAvailable`, which:

1. lists every zone in the private database and keeps those named
   `MealPlanHousehold-…` whose root `MPHousehold` record decodes;
2. picks one deterministically — a zone that carries a `CKShare` first
   (that is the household the owner deliberately shared), otherwise the oldest,
   with the zone name as a final tie-break;
3. pages the whole zone down with `recordZoneChanges`, reporting progress;
4. stops any engine that may already be attached to a placeholder zone, applies
   every record in priority order, and writes an owner locator.

Discovery also runs when the local household is an empty placeholder — older
builds created one immediately on each new device — so those devices heal
themselves instead of staying stuck with an empty plan. `RootView` shows the
"Checking iCloud… / Downloading… / Preparing your household…" overlay from
`AppState.cloudBootstrapState` for the whole operation, and onboarding waits
for it so a returning user is not offered the first-run tour again.

**Opening your own invitation link on your own second device.** CloudKit
refuses to let an account accept its own share into the shared database, so
`HouseholdCloudSharingService.accept` checks for that case first: if the
current user is the share's owner, or the zone is already visible in the
private database, it treats the link purely as a locator and calls
`restoreOwnedHousehold` for that zone instead of `CKContainer.accept`.

From then on the second device is an ordinary owner device: private database,
`isOwner = true`, same scan, same conflict rules.

## Collaborating with other people

### Creating the invitation

`HouseholdCloudSharingService.prepareInvitation` pushes any pending local
changes, then creates (or re-fetches) a **zone-wide** `CKShare` for the
household's existing zone. Nothing is copied or re-encoded: the same records
the owner has been syncing all along simply become visible to participants.
The share gets a title, a `shareType` of
`de.holgerkrupp.mealplan.household`, and a `householdID` field so a
participant can address the root record by ID without a CloudKit query.

Access is granted through `share.publicPermission` — `.readWrite` or
`.readOnly`, from the sheet's Access picker — which means **anyone holding the
link can join** at that permission. Per-person `oneTimeURLParticipant`
invitations would be tighter, but `addParticipant(_:)` traps rather than
throws without Apple's restricted
`com.apple.developer.icloud-extended-share-access` entitlement, which crashed
the app on every invitation. The sheet says so in plain language next to the
link.

`HouseholdSharingView` presents the resulting URL three ways — a `ShareLink`,
a copy button, and a QR code for the phone sitting next to you — and offers
**Create New Invitation** (`replaceInvitation`), which deletes the `CKShare`
and immediately makes a new one. Deleting a share stops sharing the zone but
keeps the zone and every record in it, so this is the safe repair for a link
CloudKit can no longer resolve; everyone who had joined loses access and needs
the new link. Only the owner sees any of this: `isOwner(shareIdentifier:)`
gates both the sheet's controls and the "Share with family" row in
`HouseholdSettingsView`.

### Receiving the invitation

An invitation can arrive through three different system paths, and MealPlan
handles all three because the polite one is not reliable:

- the app is launched by the invitation — `MealPlanSceneDelegate`'s
  `scene(_:willConnectTo:options:)` finds `cloudKitShareMetadata` in the
  connection options;
- the app is already running — `windowScene(_:userDidAcceptCloudKitShareWith:)`
  on iOS, `application(_:userDidAcceptCloudKitShareWith:)` on macOS;
- the system hands over the raw URL instead (a link opened inside another
  app's browser, a chat app's preview, or a tap while MealPlan is frontmost) —
  `AppState.handle(openedURL:)` recognises it with
  `HouseholdCloudSharingService.isShareURL` and resolves the metadata itself
  with `CKContainer.shareMetadata(for:)`.

SwiftUI does not install an app-owned scene delegate unless one is provided,
which is why `AppDelegate.application(_:configurationForConnecting:options:)`
exists at all; without it iOS opens the app after the acceptance sheet and
never delivers the metadata.

All three paths funnel into `HouseholdShareInvitationInbox`, which holds the
metadata until `RootView` has a `ModelContext` to accept it into. Its
`CloudShareDeliveryGate` keys deliveries by container, zone owner, zone name,
and share record name so two lifecycle callbacks for the same link cannot race
two acceptances. A failed or cancelled join re-arms that key, so opening the
link again works.

### Joining

Because MealPlan keeps exactly one household per device, joining replaces
whatever household this device had. `RootView` therefore asks first, whenever
`localHouseholdAtRisk(ofAccepting:context:)` finds a local household with
dishes or plan entries (that check does no networking, so nothing is touched
unless the person continues):

- **Merge Recipes** — dishes and the ingredients they need move into the joined
  household first; plan, shopping list, and history do not.
- **Replace Everything** — the old household is deleted outright.
- **Cancel** — the invitation stays available for another attempt.

`accept` then does the work:

1. `CKContainer.accept(metadata)`. Acceptance is not usefully idempotent — a
   second delivery of the same URL can report "share not found" although the
   first succeeded — so a failure falls back to looking the share up in the
   shared database, and only a genuinely stale or wrong-environment link is
   turned into `invitationNotFound`.
2. The root `MPHousehold` record is fetched, retried up to six times about
   two thirds of a second apart, because CloudKit may still be making the
   zone's records visible.
3. The household is upserted by its durable UUID, any other local household is
   merged or deleted, and a participant locator is written (`isOwner = false`,
   `isReadOnly` from `currentUserParticipant.permission`).
4. The member roster is refreshed and a first full sync runs, which pulls the
   rest of the household down through the shared database.

The cascade delete of the replaced household is picked up by the ordinary
safety-net scan, so its own zone is cleaned up in CloudKit too.

### Who is in the household

`refreshMembers` mirrors the `CKShare` participant list into `HouseholdMember`
rows after every invitation change and every sync. Members are matched by
CloudKit participant ID, so names and roles are updated in place rather than
re-created; someone removed from the share is marked inactive instead of
deleted. Roles map straight from CloudKit — owner, `.readOnly` participant →
guest, anything else → editor — and the participant matching
`currentUserParticipant` is flagged `isCurrentUser`. The `CKShare` is always
the authority; the local rows exist so "Who's planning" and plan attribution
can be rendered without a round trip.

One household-wide field rides along with this: `unlockedByPurchase`. A
one-time App Store unlock made by any member unlocks unlimited planning for
everyone, and a device that later joins a *different* household drops the
inherited unlock and re-checks its own purchase
(`RootView.reconcileEntitlement`).

### View-only guests

A read-only participant is enforced at three levels:

- the locator's `isReadOnly` makes `HouseholdRecordSyncService` skip local
  scanning entirely and return `nil` from `nextBatch`, so no batch is ever
  sent;
- `AppState.isGuest` disables the editing affordances throughout the UI —
  planning, dish editing, routines, staples, feeds, import, translation, menu
  commands;
- CloudKit itself rejects a write to a `.readOnly` share, which is the boundary
  that actually matters.

## When things go wrong

The local store is always usable. Network failures during the periodic sync are
swallowed on purpose (`RootView.synchronizeHousehold` ignores
`.networkUnavailable` / `.networkFailure`), pending changes and serialized
engine state survive relaunch, and the next push, save, or launch retries.
Anything else surfaces in the "iCloud sharing needs attention" alert with the
message from `HouseholdSharingError`, which is written to say what to do next
rather than what failed.

The most common real-world failure is an environment mismatch: CloudKit's
Development and Production databases share nothing, so an invitation created
from an Xcode build cannot be accepted by a TestFlight build. `BuildEnvironment`
reads the embedded provisioning profile to know which environment a build talks
to, the sync state is namespaced by it, and `invitationNotFound` says
explicitly that both phones need MealPlan from the same source. Where a link
has genuinely gone stale, **Create New Invitation** re-issues it without
touching any data, and the JSON backup in Settings ▸ Data transfer remains the
manual recovery path.

## Deliberate omissions

- No `UICloudSharingController`. The app presents its own sheet so it can offer
  the QR code, the access picker, and the re-issue action on both iOS and
  macOS.
- No SwiftData CloudKit mirror alongside `CKSyncEngine`.
- No per-person invitations, for the entitlement reason above.
- No more than one household per device.
- No migration from the old whole-household `MealPlanBackup` sharing asset; the
  cutover to per-record sharing was a clean break.

## What is covered by tests

`MealPlanTests/HouseholdRecordSyncTests.swift` covers locator round-tripping
and permission preservation, record identity naming, zone-to-household
identity, legacy shares without a `householdID` field, the bootstrap candidate
ordering, environment namespacing of sync state, both two-clock merges, the
"equal check clocks prefer checked" rule, and the photo/asset conflict rules.
`MealPlanTests/HouseholdCloudSharingServiceTests.swift` covers share-link
recognition, the at-most-once delivery gate with its retry, and the window
scene configuration that delivers invitations at all.
