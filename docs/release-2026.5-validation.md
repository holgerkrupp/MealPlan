# MealPlan 2026.5 collaboration release check

The package dependency is pinned in the Xcode project and `Package.resolved`.
MealPlan's SwiftData store remains local, with the package's CKSyncEngine pool
as the sole CloudKit transport for household records.

## Automated checks

- Build the `MealPlan` scheme for macOS Release and iOS Simulator Debug.
- Run `HouseholdRecordSyncTests` and `HouseholdCloudSharingServiceTests` on macOS.
- Run the full macOS test suite before archiving.
- Verify a clean checkout resolves CloudKitCollaborationKit at revision
  `860b0f3d5950a9129056c2056a00e21cb08827b0`.

Verified on 2026-10-15 with Xcode beta: macOS Debug and Release builds,
iOS Simulator Debug and Release builds and 751/751 macOS tests, including the
focused sync and sharing tests. The sibling CloudKitCollaborationKit package passed 13/13
tests. The automated test build used `CODE_SIGNING_ALLOWED=NO`.

A separate Apple Development signed macOS Debug build exercised the owner's
real CloudKit Development database with 3,509 records. The original failure
was a partial `serverRecordChanged` send involving older records without
server change tags. After conflict reconciliation, its journal and pending
fingerprints both reached zero. A subsequent format update uploaded 63 recipe
feed records once, then drained to zero. The next launch queued no household
records and wrote no change journal. This verifies owner-account upload and
an unchanged relaunch; it does not verify another Apple Account, invitation
acceptance, or the CloudKit Production environment.

A live profile of Household settings found that changing standard portions
recomputed ingredient duplicate suggestions on the main thread. Removing that
calculation from the settings label and reusing one matching index per cleanup
run eliminated the observed stall. In the signed build, the household view
opened promptly and servings changes and restoration completed without a
beachball; the original value of 3 was restored.

Crash Organizer reports received later on 2026-10-15 identified two iPhone
regressions. Builds 2026.4 (44) and 2026.5 (50) aborted while Settings read
`Household.mealTypes` from an upgraded SwiftData store. The Settings summary,
record snapshot, meal reconciliation, and backup upsert now fetch `MealType`
directly. Build 2026.5 (51) was terminated with `0xdead10cc` while preparing
CloudKit records: iOS no longer holds the Mac-only sync ownership file lock,
and the snapshot actor is constructed away from the main actor. The updated
iOS Simulator build and focused macOS sync tests pass; these fixes still need
signed device validation.

A five-second sample of the Developer ID signed Production build 2026.5 (51)
on macOS showed the main thread repeatedly rebuilding all household snapshots
for pending CKSyncEngine records. The send callback now reconstructs missing
journal snapshots once per batch and invokes SwiftData snapshot work from a
detached task. The running build 51 does not contain these later changes.

Build 52 archives successfully for macOS Release and builds for iOS Simulator.
The focused sync and sharing suites pass 31/31 and 4/4 tests. The full macOS
suite passed 752/752 tests with Xcode 27.0 on 2026-10-15. An earlier run with
the Xcode 27.1 beta aborted inside Core Data while several SwiftData tests ran
together; the stable Xcode run completed without that test-host failure.
The iOS 27.0 simulator passed all 753 tests with stable Xcode, including the
38 sync, sharing, and meal-type recovery tests. Simulator tests do not exercise
Production CloudKit pushes or the iOS background-suspension kill path.

The build 52 archive is Apple Development signed. Exporting it for direct
Production distribution is blocked on this Mac: Xcode reports no signed-in
account or Developer ID Application signing certificate with its private key.
The notarized Production app currently on the Desktop is build 51 and predates
the crash and performance fixes. Build 52 still needs Developer ID export,
notarization, signed-device checks, and Production CloudKit collaboration
validation before release.

## Signed device checks required before distribution

Use two Apple Accounts and signed builds with the same CloudKit environment.
Repeat the invitation path on macOS and iPhone or iPad. Record the app version,
OS versions, account roles, CloudKit environment, and whether the household
already existed on each device. No account names or invitation URLs belong in
the run notes.

1. Launch a second device on the owner's Apple Account. Confirm that its
   household, recipes, plans, and shopping list appear once, with no duplicate
   household or zone.
2. Invite a different Apple Account as editor through Apple's sharing UI.
   Accept the invitation, then edit a recipe, plan item, and shopping item on
   both devices. Confirm the changes converge after each device goes offline
   and reconnects.
3. Repeat with view-only permission. Confirm the recipient can read data but
   cannot mutate it. Change that permission through Manage Access and verify
   the new role on the recipient device.
4. Open an existing household share made by the previous release. Confirm the
   existing share ID and accepted participants remain in place. If CloudKit
   cannot verify a legacy participant, confirm the share stays unchanged and
   the owner receives the error when they choose Invite or Manage Access.
5. Remove a participant and stop sharing. Confirm the recipient keeps their
   own recipes and does not delete the owner's household data. A temporary
   network error must leave the shared household on the device.
6. Force quit after a local edit before upload, then relaunch. Confirm the edit
   reaches another device. Repeat after a received remote edit.
7. On a household with at least 1,000 records, measure menu opening during a
   cold fetch and after sync settles. An unchanged launch should queue zero
   records; one edit should queue only the changed record and its explicit
   related records. Record CloudKit operation counts and main-thread stalls.
8. On iPhone, open Settings with a store upgraded from build 44 or 50. Confirm
   the Meals summary loads. Edit a meal type, send the app to the background
   during a large household sync, and resume it. Confirm there is no
   `0xdead10cc` termination and the edits reach the other device.

Run the same account and invitation cases with the intended TestFlight or App
Store signing profile before release. Development and Production CloudKit
databases are separate, so a Development run does not validate Production.
