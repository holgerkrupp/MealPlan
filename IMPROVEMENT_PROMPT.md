# MealPlan improvement brief

A prompt for an agent working in this repository. It covers four areas where
MealPlan is behind Mela: cooking mode, recipe discovery, household sharing, and
ease of use.

---

## Context

MealPlan is a SwiftUI + SwiftData meal planner for iPhone, iPad and Mac
(iOS/macOS 26 minimum). Targets: the app (`MealPlan/`), a share extension
(`MealPlanShareExtension/`), widgets (`MealPlanWidgets/`) and a shared framework
(`MealPlanShared/`) holding the models, units engine and import/export code.
One SwiftData store lives in the App Group `group.de.holgerkrupp.mealplan` and
mirrors to the private CloudKit database (`SharedStore.container`).

Read before starting: `MealPlanShared/Support/SharedModelContainer.swift`,
`MealPlanShared/Support/HouseholdCloudSharingService.swift`,
`MealPlanShared/Support/MealPlanBackupSync.swift`,
`MealPlan/Features/DishLibrary/CookingModeView.swift`, and
`MealPlanShared/Support/RecipeSchemaParser.swift`.

### Constraints that apply to every workstream

- **No servers, no third-party services, no new package dependencies.** iCloud
  (CloudKit) and Apple frameworks only. The existing Bring! integration is the
  sole external API and is out of scope.
- Keep the `MealPlanShared` split intact: models, parsing and sync logic belong
  in the framework so the extension and widgets can use them. Only UI belongs
  in `MealPlan/`.
- Every user-facing string goes through `String(localized:)` and gets both
  **English and German** entries in `MealPlan/Localizable.xcstrings`.
- Match the existing house style: `@Observable` over `ObservableObject`,
  `async`/`await` over completion handlers, `enum` namespaces for stateless
  helpers, and comments that explain *why* a decision was made (see the
  existing files — that voice is deliberate, keep it).
- Pure logic — parsing, merging, aggregation — goes in testable types with
  tests in `MealPlanTests/`, not inside a `View`.
- Anything user data can be lost to needs a migration path and a guard against
  running twice.

Work the four parts in the order given. Parts 1, 2 and 4 are self-contained.
**Part 3 is an architecture change — produce the written plan and get it agreed
before writing migration code.**

---

## Part 1 — Cooking mode

`CookingModeView` handles one recipe, keeps its timers in `@State`, and throws
away all progress when dismissed. Cooking a real meal means several dishes at
once, and a timer that dies when you leave the view is worse than no timer.

**Cook a menu, not a recipe.** Introduce a cooking *session* that holds one or
more dishes. The user starts from a dish as they do today, then adds more —
from the library, or from everything planned for the same meal slot on the same
day, which should be offered as a one-tap suggestion. Switching between dishes
preserves each one's step position, checked ingredients and serving count
independently.

**Timers that outlive the view.** Lift timers out of `@State` into an
observable session model that survives dismissal, and surface running timers as
an ActivityKit **Live Activity** so they appear on the Lock Screen and in the
Dynamic Island (iOS only — guard for macOS, which has neither). A timer must be
labelled with both its dish and its step, because two things are boiling. Keep
the existing "durations detected in the step text become one-tap timers"
behaviour and add a manual timer for the ones the text does not state. Timers
must fire correctly when the app is backgrounded or killed — schedule the
notification up front rather than relying on a live process.

**Resume where you left off.** Persist session progress so a session
interrupted by a phone call, or by the app being swept away, offers to resume.
The current reset-on-open behaviour is a defensible default for *finished*
sessions — keep that, but distinguish "I finished" from "I was interrupted".

**Reading at the stove.** Adopt Mela's focus treatment: the current step at a
comfortably larger size with the surrounding steps dimmed rather than hidden,
so a cook can see what is coming. Add a text-size control that persists.

While you are in this file: `isIdleTimerDisabled` is set and cleared
unconditionally, so two overlapping screens that both want the display awake
will fight. Make it reference-counted.

---

## Part 2 — Discovery

MealPlan can capture a recipe from anywhere — web, social video, a scanned
cookbook page — but it cannot help you *find* one. Mela's answer is feed
subscriptions, and it is the right one: recipe blogs publish RSS, and reading
them inside the app turns a recipe manager into somewhere you go when you don't
know what to cook.

**Feeds.** Let the user subscribe to recipe blogs and read new posts in-app.
Parse RSS 2.0, Atom and JSON Feed with `XMLParser` and `JSONDecoder` — no
dependency. Given a site's home page URL, discover its feed automatically from
the `<link rel="alternate">` tags rather than making the user find the URL.
Fetch on demand and on app foreground, never on a background timer; honour
`ETag` and `Last-Modified` so a refresh that finds nothing costs nothing, and
back off on repeated failure. A feed that 404s for a fortnight should say so
plainly rather than failing silently.

**Reading, then saving.** An article opens in a clean reader view, with one
button that runs it through the existing `RecipeSchemaParser` and saves it as a
dish. This is the whole point of the feature — the path from "that looks good"
to "it's in my library" must be one tap, and when the page carries no recipe
markup the button should say so rather than saving an empty dish.

**Bookmarks.** A small list of recipe sites the household returns to, opening
in the existing in-app browser (`RecipeFinderView`), which already has the
"Use this recipe" affordance.

**Where it lives.** Feeds and bookmarks are new `@Model` types in
`MealPlanShared/Models/`, synced with everything else. Unread state is
per-person, not per-household — do not make one person's reading mark the
family's. Fetched article bodies are a cache: keep them out of the backup
payload and out of CloudKit, and cap what you store on disk.

**Don't build a feed reader.** No folders, no OPML, no read-later queue, no
unread badge counts. The bar is "I saw something good and now it's in my
library", and every screen you add past that is a screen a cook has to learn.

---

## Part 3 — Real multi-writer household sharing

This is the largest piece and the one with the most to lose. Read it fully
before writing code.

### What is wrong today

`HouseholdCloudSharingService` does not share the household; it ships a copy of
it. The whole store is serialised into a `MealPlanBackup` JSON blob, attached as
a single `CKAsset` on one record in a custom zone, and that record is shared by
`CKShare`. Sync is `synchronize(_:context:)` comparing SHA-256 hashes of the
whole document, and merging is `MealPlanBackupSync.merging`, which unions
entities by ID and resolves collisions by "whichever backup was *exported*
later wins".

Three consequences, all of them things a household will hit:

1. **Deletes do not propagate.** `merging` keeps any row present on only one
   side. Delete a dish on your phone, and your partner's copy — which still has
   it — puts it straight back on the next sync.
2. **Concurrent edits lose data.** The unit of conflict resolution is the
   entire household. Two people editing different dishes in the same window
   means one of them silently loses their edit, because the newer *export*
   wins wholesale.
3. **It does not scale and is not live.** Every sync uploads and downloads the
   entire library, photos included, and only when something calls
   `synchronize`. There are no push notifications, so a plan changed on one
   phone does not appear on another until the app is opened and reconciles.

The file's own comment explains the original reasoning correctly: SwiftData's
managed CloudKit store mirrors the **private** database only, and there is no
`cloudKitDatabase: .shared`, so a `CKShare` had nowhere to root itself. That
constraint is real. The blob was a reasonable way around it. It is not a way to
get multi-writer.

### The target

Real per-record sync, over iCloud only, with per-entity conflict resolution and
deletes that stick.

The way to get it without a server is **`CKSyncEngine`**, which handles change
tokens, batching, retry and push subscriptions, and — unlike SwiftData's
mirroring — works against the **shared** database as well as the private one.
SwiftData stays the local source of truth; CloudKit becomes a transport moving
one record per entity instead of one blob per household.

**The hazard to design around first:** SwiftData's own private-database
mirroring and a hand-run `CKSyncEngine` must not both sync the same models, or
they will duplicate and fight. Resolve this explicitly. The recommended
resolution is to move household-scoped models onto `CKSyncEngine` entirely —
private zone when the household is solo, shared zone once it is shared — so
there is exactly one sync path and multi-device continuity for a solo user
comes from the same code as sharing. Note the cost honestly in your plan:
turning off `cloudKitDatabase: .private` means every device re-syncs from
scratch once, and SwiftData's mirroring quietly did work you now own —
schema migration among it.

Requirements for the new layer:

- **One CKRecord per entity.** `Dish`, `DishIngredient`, `MealPlanEntry`,
  `Ingredient`, `MealType`, `MealRoutine`, `CookedLog`, `ShoppingListItem`,
  `WeekTemplate`, `WeekTemplateEntry`, plus the `Household` root. Images are
  `CKAsset`s on their own records, never inlined, so editing a dish's name does
  not re-upload its photos.
- **Deletes propagate.** Use CloudKit's own record deletion. Where a local
  delete must survive an offline period, record a tombstone with the deletion
  time so a stale peer's edit cannot resurrect the row.
- **Conflict resolution is per record**, using CloudKit's server record
  comparison. Add a `modifiedAt` to each synced model and take last-writer-wins
  per record as the default — but not everywhere. Two cases deserve better and
  should be spelled out in the plan: the shopping list, where two people
  ticking different items must not undo each other and checked state should
  merge rather than overwrite; and plan entries, where a move and an edit in
  the same window should both survive.
- **Live updates.** Subscribe for push so a change on one device reaches the
  others without the app being opened. Sync on foreground, after local writes
  (debounced), and on push.
- **Roles hold.** A `.readOnly` participant is currently only prevented from
  editing by the UI. Once records sync individually, enforce it: a guest's
  writes must be rejected, not merely discouraged.
- **Members come from the share.** `refreshMembers` deletes every
  `HouseholdMember` and rebuilds the list on each sync, which throws away any
  local state attached to a member and is exactly the delete-and-recreate
  pattern that breaks under concurrent sync. Reconcile by participant identity
  instead.

### How to proceed

Do not start by editing `HouseholdCloudSharingService`. Start by writing
`docs/sharing-architecture.md` covering: the record schema and zone layout; how
a household moves from private zone to shared zone at the moment it is first
shared; the migration path for existing users (including someone who is
*already* in a blob-shared household and must not lose data or end up in two
households); the conflict rules per model; how the share extension and widgets
— which open the store without CloudKit — fit; and the rollback plan if
migration fails on a device. Include what you decided about SwiftData's private
mirroring and why.

Then phase the work so each step ships something testable:

1. Sync engine and record schema, private database only, behind a flag, with
   the blob path still live and authoritative.
2. Migration: existing store to per-record sync, with a backup written first
   and a guard against re-running.
3. Shared database, `CKShare` on the household zone, invitation and acceptance
   moved over to it.
4. Blob path retired, with a compatibility window during which a device on the
   old version can still be brought across.

Test at minimum: two devices editing different dishes concurrently; two devices
editing the same dish; a delete on one device against an edit on the other; a
device offline for a week then reconnecting; a guest attempting a write; and a
participant removed from the share.

---

## Part 4 — Ease of use

MealPlan asks a cook to learn roughly fourteen concepts — dish, variant group,
collection, tag, meal-type tag, dietary tag, season, meal slot, custom meal
type, routine, week template, pantry staple, household, standard portions —
against about four in Mela. The features are good. The vocabulary is the cost,
and most of it is not load-bearing.

**Five labelling systems, one job.** `collectionNames`, `tagNames`,
`mealTypeTagsRaw`, `dietaryTagsRaw` and `seasonRaw` are five ways to label a
dish, and a user cannot tell from the UI which to reach for. Collapse them.
Free-text tags (which already have suggestion, normalisation and fuzzy matching
behind them in `DishTag` and `DishTagSuggester`) are the general case; keep a
separate structured axis only where the app *acts* on it rather than merely
filtering by it — meal-type tags drive slot suggestions and season drives
`SeasonalSuggestions`, so those earn their place. Collections and dietary tags
should be strong candidates for becoming tags. Whatever you decide, the
migration must be lossless and must not create duplicates where a dish was
tagged `vegan` and also flagged `.vegan`. Present the reduction as a proposal
with the migration attached before you run it.

**Settings.** Ten sections is more than the app needs to show at once. Most of
them are one-time setup (Bring!, Reminders, calendar integration, units,
household) and a handful are ongoing. Restructure so first-run essentials are
visible and integrations sit behind a single "Connections" group — and let an
integration's own row show whether it is connected, so nobody opens three
screens to check.

**Meet people where the work is.** Several settings would be better as actions
in context: the standard serving count next to a dish's servings, meal-slot
configuration from the calendar, pantry staples from the shopping list where
you notice you are buying salt again. Move what you can and leave the setting
as a mirror.

**First run.** Onboarding's four pages lead with the share extension, which is
right. What follows is an empty library, which is the moment most people leave.
Offer a small starter set of dishes the household can plan with on day one, and
make it obvious they can be deleted.

**Say the paywall out loud.** Free planning stops seven days out. Right now the
user meets that as a blocked day. Say what the limit is before they hit it, and
when they do hit it, show it as a boundary in the calendar with the reason
attached — not an error.

**Measure the result.** For each change, state the concept count before and
after and the taps to a first planned meal from a cold install. If a change
does not reduce one of those, it is not an ease-of-use change and belongs in a
different part.

---

## Definition of done

- Builds for iOS and macOS with no new warnings.
- New pure logic — feed parsing, conflict resolution, tag migration — is
  covered by tests in `MealPlanTests/`.
- Every new string is localised in English and German.
- No new third-party dependency; nothing leaves the device except to iCloud.
- Migrations are idempotent and take a backup first.
- `docs/sharing-architecture.md` is written and agreed before Part 3 phase 2.
- Each part lands as its own commit, in the order above, with the reasoning in
  the commit message.
