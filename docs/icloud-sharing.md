# Household sharing and CloudKitCollaborationKit

MealPlan keeps SwiftData as its app database and uses the sibling
`CloudKitCollaborationKit` package for CloudKit share lifecycle, sync-engine
ownership, invitation acceptance, and native sharing UI. MealPlan continues to
own its household schema, record codec, merge rules, and SwiftData import.

## Ownership

| Component | Responsibility |
| --- | --- |
| `SharedModelContainer.swift` | Opens the App Group SwiftData store with SwiftData CloudKit mirroring disabled. |
| `HouseholdRecordSyncService.swift` | Captures MealPlan records, applies package sync events, and serializes app-specific conflicts and tombstones. |
| `MealPlanCloudKitStateStore.swift` | Adapts MealPlan's App Group persistence to the package's database-scoped engine state and pending-change journal. |
| `MealPlanShared/Support/MealPlanCloudSharing.swift` | Resolves MealPlan household roots and supplies MealPlan's flush and locator callbacks to the package. |
| `HouseholdCloudSharingService.swift` | Keeps MealPlan's SwiftData import, household replacement warning, member cache, and removed-access recovery. It does not create or edit CloudKit shares. |
| `CloudSharingView.swift` | Shows package-provided share links and Apple's native sharing and participant controls. |
| `MealPlanApp.swift` / `HouseholdShareInvitationInbox` | Receives CloudKit invitation metadata and queues it until SwiftData and the replacement preflight are ready. |
| `RootView.swift` | Presents the replacement choice, calls the package acceptance service, and drives the app's household sync. |

The package is pinned to revision `860b0f3d5950a9129056c2056a00e21cb08827b0`
from its GitHub repository, so release builds do not need a sibling checkout.
MealPlan uses its `CollaborationCore`, `CollaborationCloudKit`, and
`CollaborationUI` products. MealPlan keeps its existing SwiftData snapshot
codec and deletion-marker recovery while handing engine ownership to the
package. The package's optional incremental SwiftData history adapter remains
available to hosts whose model graph and history policy fit that approach; it
does not replace or migrate MealPlan's database.

## Existing data and safe migration

The migration is in place. MealPlan preserves the household UUID, SwiftData
store, custom zone (`MealPlanHousehold-<UUID>`), record names, and zone-wide
share identity. The package's root resolver points at those same records, so
first package use reuses the existing share. If that share still allows
anyone-with-the-link access, the package closes that access only after it can
restore every accepted person's identity and previous permission. If it cannot
confirm an identity, it leaves the share unchanged. Accepted people keep their
access; the owner can send a new invitation to anyone whose prior invitation
was still pending through Apple's sharing UI.
When a new share is needed, the package prepares it in the same zone after
MealPlan flushes its pending local changes.

Engine ownership moves to the package's `CloudKitSyncEnginePool`. MealPlan's
state-store adapter partitions serialized state by CloudKit environment,
account, and database scope. On first use, it imports the previous per-household
engine serialization for the matching private or shared database, verifies the
new file-backed copy, then removes the legacy defaults key. The host continues
scanning SwiftData records and journaling app-specific record payloads, assets,
fingerprints, and deletion
markers; the package persists engine state and replays staged changes.
Photo assets use content-addressed files so a later edit cannot replace bytes
already queued for CloudKit. A server acknowledgement removes a journal entry
only when it matches the queued record version.

Opening the sharing screen reads the existing share without preparing or
rewriting it. Invitation and management actions prepare the authoritative
share when tapped. Accepted participants keep their access when the package
can verify their identities; an unresolved legacy participant leaves the
share unchanged and produces an actionable error.

## Sync and sharing

MealPlan writes one CloudKit record per household entity, using stable names
such as `MPDish-<UUID>`. Its record codec and conflict resolver remain in the
app because they encode MealPlan's SwiftData model and merge behavior. The
package pool owns the private/shared `CKSyncEngine` instances, their state,
subscriptions, retry behavior, and change delivery. The app serializes explicit
fetch and send operations and keeps sync disabled from automatic overlapping
operations so its record scan and SwiftData apply path remain ordered. A scan
does not requeue records that match their pending or acknowledged version.

`MealPlanShareRootResolver` supplies the existing household root record,
custom zone, title, and MealPlan-owned share fields. The package finds or
prepares a zone-wide `CKShare`, persists the stable share locator through the
host callback, and provides the current share and participant/access snapshots.
The package UI uses Apple's share link and participant manager on iOS and the
native CloudKit sharing service on macOS. There is no second email/phone
invitation form, QR invitation, or app-owned participant editor.

CloudKit delegate and scene callbacks still belong to the host application.
They queue metadata until the local store is ready. Before accepting an
invitation, MealPlan warns if this device has a populated household that would
be replaced and offers the existing recipe-merge choice. For a participant,
the package accepts the share and invokes MealPlan's callback before fetching
shared records; the callback checks the cloud environment, imports the root
record into SwiftData, preserves recipes if selected, and sets the household
locator. The package then starts and fetches through its sync pool. Opening an
owner's link on another device continues to use MealPlan's existing private
household restore path because an owner cannot accept their own share into the
shared database.

Package participant snapshots update MealPlan's local `HouseholdMember` cache
and access projection. If a participant's share is authoritatively gone, the
existing recovery path creates a household on that device and carries over its
recipes and preferences. Temporary network failures do not trigger that path.

## Configuration

The app still needs the `iCloud.de.holgerkrupp.mealplan` CloudKit container, the
`group.de.holgerkrupp.mealplan` App Group, `CKSharingSupported`, and remote
notification background mode. The app, widget, and share extension link the
package CloudKit/Core products because the shared sync adapter is compiled into
those targets; only the main app invokes the share lifecycle and sharing UI.
