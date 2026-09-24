# MealPlan on iPhone Duo

Analysis date: 2026-09-14. This plan applies Apple’s iPhone Duo guidance to the current SwiftUI meal planner.

Revision 2026-09-14 (second pass): re-read the published HIG page and added layout options per surface, control ownership, bar-free cooking surfaces, an explicit open/close transition contract including drag sessions, and the conditional reserved regions — including the Dynamic Island expansion caused by the cooking-timer Live Activity. Nothing from the first pass was removed.

Revision 2026-09-19: added implementation details from Apple’s new preparation technology overview, including container-specific bar behavior, toolbar APIs, arrangement-hosting cautions, camera direction, and pose-by-pose validation.

## Recommendation in one sentence

Keep tabs and a focused planner on the outer display, use the existing sidebar and calendar/dish workspace on the inner display, and make planning and cooking layouts fold-aware so a book pose supports drag-and-drop planning and a tabletop pose becomes a hands-free cooking station.

## Device and platform baseline

| Surface | Hardware size | Pixels | Early @3x layout target | Size-class guidance |
| --- | --- | --- | --- | --- |
| Outer display | 5.4-inch | 1398 × 2034 | about 466 × 678 pt | Compact-width iPhone experience |
| Inner display | 7.6-inch | 1878 × 2670 | about 626 × 890 pt or 890 × 626 pt when rotated | Regular width and regular height |

The point sizes are derived planning targets, not Apple-published viewport values. Use live scene geometry, layout margins, safe areas, and reserved regions. The usable area is smaller and asymmetric when vertical bars, cameras, the fold, or Split View are active.

Building with iOS 27.1 SDK opts the app into the full inner display and standard vertical bars. Keep the iOS 26 deployment target by wrapping `ArrangementView`, reserved-region APIs, bar priorities, and other iOS 27.1 additions in availability checks.

## Apple rules that matter here

- Design for compact and regular size classes across a continuum. Don’t create a separate hard-coded layout for every pose.
- Keep the same functionality and state between displays. The inner display may expose an additional level of hierarchy.
- A partially folded inner display has an active division reserved region. Controls and indivisible cards must avoid it.
- Standard split views, tab views, stacks, lists, scroll views, sheets, alerts, and menus adapt automatically.
- Use `ArrangementView` for an existing two-view content relationship. Keep navigation outside it.
- Prefer even grid columns when content can span both sides of the fold.
- On the outer display and inner landscape, standard bars move to a vertical edge. Use symbols plus titles, sensible groups, overflow, and visibility priority.
- In tabletop pose, put glanceable content above and interactive controls below.

## Current code assessment

MealPlan already has a strong adaptive foundation:

- `App/RootView.swift` uses tabs in compact width and `NavigationSplitView` in regular width. This naturally maps the outer display to tabs and the inner display to sidebar + detail.
- The compact and regular branches each create their own `NavigationStack`. The selected `AppSection` lives above them, but navigation depth and sheet-owned drafts may not survive a live compact ↔ regular transition.
- `Planning/PlanView.swift` shows `CalendarHomeView` plus a draggable, resizable `DishSidebarView` when `PlanLayoutPolicy` says both fit. The inner landscape planning width should satisfy the regular-width threshold, but the custom `HStack` doesn’t avoid an active fold.
- `PlanLayoutPolicy` deliberately checks geometry/aspect for compact landscape. That fallback is reasonable on iOS 26, but Duo’s inner display is regular in both dimensions and layout should be driven by arrangements/reserved regions on iOS 27.1.
- `WeekSectionView` uses two equal meal columns. The even count is fold-friendly, although the outer display and large text still need a one-column fallback if cards become cramped.
- `DishLibraryView` already uses an adaptive recipe grid and bounded cell widths.
- `CookingModeView` has exactly the right semantic material for Duo: ingredients and instruction/timers in independent panes, a left-handed mirror option, voice control, and persistent cooking-session state. Its side-by-side mode currently requires compact width + compact height + wide geometry, so the regular inner display will miss it.
- `ShoppingListView` is a standard `List`, which should adapt safely. Its range/rebuild controls and large toolbar menu need vertical-bar prioritization.

## Layout by display and pose

| Configuration | Proposed MealPlan layout | Fold behavior |
| --- | --- | --- |
| Closed, outer display | Keep Plan, Dishes, Shopping, and Settings tabs. Plan is a focused calendar. Provide an obvious “Choose dish” action when drag-source sidebar is absent. | Preserve selected tab, date/week, scroll anchor, open recipe, search/filter, shopping checks, and any editor draft on open. |
| Fully open, inner landscape | Sidebar for app sections; detail workspace. Plan shows calendar plus dish browser. Dishes may show grid + selected recipe. Shopping can show list + pantry/detail where useful. | Prefer standard navigation splits and content arrangements so the inactive fold is already the intended central gutter. |
| Fully open, inner portrait | Keep sidebar/detail if it remains useful; allow system overlay/collapse. Cooking may use stacked content with readable maximum width. | Bars become horizontal without changing destinations or actions. |
| Partially folded like a book | Planning: calendar in one region, dish search/list in the other for direct drag-and-drop. Recipe library: grid/list in one region, selected recipe in the other. | No meal card, dish tile, drag target, picker, or action straddles the fold. |
| Tabletop/laptop pose | Cooking: current instruction, timers, and progress in the upper viewing region; ingredients, servings, Next/Back, voice, and timer controls in the lower region. | The cooking session stays identical while panes reorganize top/bottom. |
| Standing/tent/edge poses | Use a focused recipe/cooking/timer view with large targets and voice control. | Avoid centered custom overlays that can land on the fold; use system sheets/alerts. |
| Split View multitasking | Collapse dish sidebar and secondary recipe detail before reducing essential calendar or cooking controls below usable widths. | Every divider position remains functional; no dependence on full-display pixels. |

## Layout options per surface

The pose table says what should happen. These are the containers that can produce it, so each choice is deliberate rather than inherited from the current geometry policies.

### Plan

| Option | Container | When it is right | Cost |
| --- | --- | --- | --- |
| P1 — split arrangement | Primary: `CalendarHomeView`. Secondary: `DishSidebarView`. | The recommended inner-display default. It splits horizontally when the region is wider than tall and vertically when taller, and gives a book pose one pane per side without any pose test. | The drop targets now sit either side of a hinge; see the drag rules below. |
| P2 — calendar only, dish picker on demand | The outer display, and narrow Split View widths. | Keep as the compact form, but add the visible picker action so the same functionality exists on both displays. | One extra tap to plan a meal. |
| P3 — calendar plus selected day detail | An alternative inner layout where the second pane is the selected day rather than the dish library. | Useful at large Dynamic Type, where a week grid and a dish list together are too dense. | Dish browsing returns to a sheet. |

A split arrangement can be limited to a single axis. Prefer that over writing pose conditions: if the dish list is unusable as a short strip under the calendar, constrain the plan arrangement to the horizontal axis and let the system show a single pane when a region cannot host both.

### Dish library and recipe

| Option | Container | When it is right |
| --- | --- | --- |
| R1 — grid plus selected recipe | `NavigationSplitView` content and detail. | The inner display default. Recipe reading keeps the library in view. |
| R2 — grid only, recipe pushed | The outer display and narrow widths. | The existing compact behaviour; keep it. |
| R3 — recipe plus inspector | Recipe detail with nutrition, variants, or planning context alongside. | Only on a wide flat region, and only where that content is genuinely reference material. |

The adaptive grid should prefer an even column count whenever it spans both usable regions, so the content divides cleanly at the hinge, and should fall back to a single column at large text sizes rather than shrinking cells.

### Cooking

| Option | Container | When it is right |
| --- | --- | --- |
| C1 — split arrangement | Primary: current instruction, progress, and timers. Secondary: ingredients and servings. | The flagship inner-display layout. In a tabletop pose the instruction sits in the upper viewing region and the ingredients and touch controls in the lower one, which is exactly the pose the HIG describes and exactly how people cook. |
| C2 — single scrolling step view | The outer display and narrow widths. | Keep Next, Back, and timer controls persistently visible rather than scrolled away. |
| C3 — full-width, bar-free step view | A tent, standing, or tabletop pose on a worktop. | The HIG allows a full-width layout for visual interfaces that do not scroll, and names Calculator. A single cooking step at reading distance is the same kind of surface: large type, a handful of large targets, nothing to scroll. This is the strongest case for dropping the bars in any of these six apps, provided nothing conflicts with the Dynamic Island or status bar and every action remains reachable. |

### Shopping

| Option | When it is right |
| --- | --- |
| H1 — list only | Every display. The list is a standard `List` and adapts on its own. |
| H2 — list plus pantry staples or the selected aisle | The inner display, if the pairing survives real use. |
| H3 — list plus the plan it came from | While rebuilding a list for a date range, so the source of each item is visible. |

## Concrete changes

### 1. Preserve one semantic route across tabs and sidebar

`RootView.selection` already keeps the current section. Extend scene-level navigation ownership so opening and closing doesn’t discard:

- per-section navigation path;
- selected date, focus week, and calendar scroll anchor;
- selected dish/recipe and dish search/filter;
- shopping range, custom dates, checked visibility, and add-field draft;
- settings subsection;
- presented recipe editor/import/cooking route and its unsaved data.

Use one route model mapped into compact and regular containers. Avoid keeping important state only inside a branch that disappears when `horizontalSizeClass` changes.

### 2. Turn the calendar + dish sidebar into a split arrangement

`PlanView` already represents two peer content views, so it maps directly to a split arrangement:

- Primary: `CalendarHomeView`.
- Secondary: `DishSidebarView`.
- Put the arrangement inside the existing navigation container.
- Prefer a horizontal split for the regular inner landscape and book pose. The active fold becomes the gutter.
- Preserve `showsSidebar` as the user’s preference, not as a pose flag.

Retain the draggable-width HStack on iOS 26. On iOS 27.1, let the arrangement and reserved regions choose frames; a user-resized width may remain a preference only when flat and unconstrained.

The compact planner currently lacks the direct dish source. To satisfy the same-functionality rule, add a visible toolbar action that opens `DishPickerView`/dish search for the selected day and meal. Drag-and-drop can remain the enhanced regular-width interaction.

### 3. Make cooking the flagship Duo experience

Replace `CookingModeLayoutPolicy`’s compact-width/compact-height requirement with an iOS 27.1 arrangement:

- Primary: current instruction, progress, and active timers.
- Secondary: ingredient pane and serving control.
- Style: split, because neither pane should obscure the other.
- Book pose: instruction and ingredients side by side.
- Tabletop pose: instruction/timers above; ingredients and touch controls below.
- Flat inner portrait: vertical split or the current bounded single-column reading flow, depending on Dynamic Type.
- Outer display: current one-column scroll, with sticky/visible Next/Back and timer actions.

Keep `usesLeftHandedLayout`, but interpret it as which usable region contains the interactive instruction controls when both choices are equally valid. Don’t fight the system’s necessary top/bottom ordering in tabletop pose.

The `CookingSessionStore` is already durable above the view. Verify opening/closing does not trigger resume prompts, restart narration, duplicate timers, or drop voice-listening state. Avoid speaking the current step again solely because the layout container changed.

### 4. Make planner cards and recipe grids fold-safe

- Keep the two meal columns only when each card retains its minimum readable/tappable width. Use one column on the short outer display at larger Dynamic Type sizes.
- If a plan grid spans the full inner display, keep two or another even number of columns and increase central spacing around an active fold.
- Do not split one day card across the hinge. A day and its meal targets should move as a unit.
- `DishLibraryView`’s adaptive grid can return an odd count. Prefer an even count when the grid spans both usable regions; otherwise let each navigation column calculate independently.
- Keep dish images/backgrounds visually expansive, but inset recipe text and buttons.

### 5. Use additional hierarchy on the inner display

Useful inner-display combinations are:

- Plan + searchable dish list (highest value).
- Dish library + selected `DishDetailView`.
- Recipe detail + cooking/plan action context.
- Shopping list + pantry staples or selected aisle controls, if user research supports it.

Use `NavigationSplitView` for list/detail navigation and `ArrangementView` only for content peers. Don’t nest navigation containers inside an arrangement or place an arrangement inside a scroll view.

### 6. Audit vertical bars and sheets

- Keep standard `TabView`, `NavigationSplitView`, `NavigationStack`, and toolbar placements.
- Give every toolbar item a `Label` with title and symbol. The system can show its symbol vertically and title in overflow.
- Plan: keep Today and the dish-picker/add action visible; Share Images, Print, meal configuration, and templates can overflow.
- Cooking: keep Close, Next/Back, timer status, and any active voice indicator visible. Display/text-size controls, add-dish, translation, and less frequent speech actions can overflow.
- Shopping: keep Add and essential Share/Send action visible based on task; pantry, printing, export, hide/clear, and service setup belong in system overflow.
- Use `ToolbarItemGroup` rather than custom manual spacing. Apply visibility priority first to whole groups, then individual items.
- System sheets already avoid the fold. Review fixed detents so a short region never hides Save/Done or a required form field.

### 7. Keep each control with the content it affects

The HIG asks that controls belonging to a content area other than the trailing one stay with that area, using Mail’s list controls as its example. Once the plan and the dish library are visible at once, MealPlan’s controls have clear owners:

- Calendar-owned: Today, week navigation, meal-slot configuration, and the share or print actions for the visible plan. These act on the calendar, so they belong above the calendar pane rather than in the trailing vertical bar.
- Dish-library-owned: the dish search field, tag filters, and sorting. `.searchable` is attached in `DishLibraryView`, `DishSidebarView`, and `DishPickerView`; make sure each lands on the pane that owns the list, not on a shared container, or the field appears in the wrong bar on the inner display.
- Recipe-owned: edit, scale servings, add to plan, start cooking, delete.
- Cooking-owned: Next, Back, timers, voice control, servings, and text size. These never migrate into browsing chrome.

### 8. Reduce text-only bar buttons

Labels that include text stay in a horizontal bar; only symbols move to the vertical axis. MealPlan’s editors, importers, and pickers carry a lot of Done, Cancel, Save, and Add buttons.

- Give every item both a symbol and a title with `Label`. The title is used in the overflow menu and expanded forms even when the bar shows only the symbol.
- Keep text-only buttons to the places where a symbol would be ambiguous — typically a modal’s confirm action.
- Use `ToolbarItemGroup` rather than manual spacing; the system provides the vertical gap that keeps former top-bar and bottom-bar items distinct.
- Reserve the ellipsis for the system overflow menu and give every other menu its own symbol.
- Do not override the default placement to force a bar horizontal.

## Reserved-region integration

Use reserved regions only where custom grids or cooking/planning panes need them:

```swift
GeometryReader { proxy in
    let fold = proxy.reservedRegions(kind: .division).first?.frame
    PlannerLayout(size: proxy.size, foldingRegion: fold)
}
```

Use inactive division regions for high-level decisions such as an even grid. Use active frames to create the actual gutter. Query occlusion regions for edge-to-edge images or camera-based recipe scanning. Use hinge callbacks only for optional effects, never to choose the layout.

## The open and close transition

The pose table describes states. This section describes the event between them, which for MealPlan includes the one interaction most likely to break: a drag in progress.

### Promotion and demotion

| Outer display (compact) | Inner display (regular) | Rule on transition |
| --- | --- | --- |
| Plan tab, a week visible | Sidebar Plan selected, calendar plus dish library | The focused week, selected day, and calendar scroll anchor are identical. |
| Plan tab with a day or meal pushed | The same day selected in the calendar, its detail in the second pane | The push becomes the selection; closing re-pushes it. |
| Dishes tab with a recipe pushed | Dish grid with that recipe selected, recipe in detail | The recipe’s scroll position and any open editor survive. |
| Cooking session presented | Cooking as a split arrangement | Step index, timers, servings, voice state, and narration position are untouched. The session must not resume, re-announce, or re-prompt. |
| Shopping tab with unchecked and checked items | The same list | Check state, the add-item draft, and the field’s focus survive. |

### What may move and what may not

- May change: whether the dish library is a pane or a sheet, grid column counts, calendar density, the bar axis, whether cooking is one pane or two.
- May not change: the selected date, the recipe being read or edited, the cooking step, running timers, checked shopping items, unsaved ingredient or tag edits, or which field has focus.
- Preserve calendar and list position by anchor — the date, the dish ID, the item ID — not by content offset, because a fold changes every row height.

### A drag in progress

MealPlan is the app in this set that uses real drag and drop: `DishLibraryCell`, `DishVariantGroupView`, and `MealCard` are draggable, and meal slots are drop destinations. A book pose makes dragging a dish across the hinge the natural gesture, so it has to be correct.

- A drop target must never sit in the active folding region. A meal slot that is half under the hinge cannot be hit reliably, and the HIG asks that indivisible interactive elements avoid the region entirely.
- Keep a day card and its meal slots together as one unit. Splitting a single day across the hinge makes the drop ambiguous.
- If the device folds or unfolds while a drag session is live, the drop targets are re-laid out underneath the finger. Prefer cancelling the session cleanly, with the dish returning to its source, over completing a drop against a target that has moved. A silently misplaced meal is worse than a cancelled drag.
- The drag preview should stay legible at every size; do not size it from the full display width.
- Dropping must be idempotent. A layout change during the drop must not plan the same dish twice.

### Other interactions in flight

- Cooking timers, narration, and voice listening are owned by `CookingSessionStore` and must be entirely independent of view lifetime. A fold must not duplicate a timer or repeat the current step aloud.
- The recipe scanner’s capture session survives a pose change; scanned text and the in-progress import are not discarded.
- Focus in the shopping add field, ingredient editors, and tag editor survives only if the field identity is stable across the shell swap.

## Reserved regions that come and go

Three of the four regions are conditional, so a correct layout can become wrong without any navigation.

| Region | When present | What MealPlan must do |
| --- | --- | --- |
| Outer front-facing camera | Always, on the outer display | Never pin custom chrome to the top of the vertical axis. |
| Dynamic Island expansion | While a Live Activity is running | `CookingTimerLiveActivity` runs during cooking, which is exactly when someone is most likely to glance at the closed device on a worktop. The top of the outer display’s vertical axis grows while it is active, so any custom header in the compact cooking view must come from the live safe area. Test cooking with a running timer, not only the idle case. |
| Inner front-facing camera | Only while the camera is active | `RecipeScannerView` and `ScanRecipeSheet` activate it, and the region appears after the view has already laid out. Place capture overlays, guidance text, and confirmation controls from live reserved regions so they move aside instead of being overlapped. |
| Folding region | Only while partially open | Zero-width when flat. Use the active frame as the real gutter between calendar and dish library, and to decide whether both panes still clear their minimum widths. |

## Implementation order

1. Build with Xcode 27.1 and capture baseline behavior in Device Hub.
2. Make compact and regular navigation share scene-level routes and drafts.
3. Convert calendar + dish sidebar to a split arrangement with an iOS 26 fallback.
4. Convert cooking instruction + ingredients to a fold-aware arrangement.
5. Add even-column/minimum-width rules for meal and dish grids.
6. Audit toolbar representation, overflow, priorities, and sheet detents.

## Verification matrix

- Snapshot planning sizes: 466 × 678, 678 × 466, 626 × 890, and 890 × 626 points. Device Hub is still required for real reserved regions.
- Open/close while on each tab, deep in a recipe, editing a recipe, dragging/planning a dish, and checking a shopping list.
- Book pose: drag dishes into days on both sides of the fold; confirm the drop preview and destination card never cross it.
- Tabletop cooking: change servings, navigate steps, start timers, use voice control, then change pose. Confirm no duplicated narration/timers and no lost session state.
- Test long localized meal names, VoiceOver, Reduce Motion, Bold Text, and the largest accessibility sizes.
- Test right-to-left layouts and left-handed cooking together; follow actual safe-area edges rather than assuming symmetry.
- Test Split View at every divider position and with the video/app stacked layout.
- Verify recipe scanner, import, share, paywall, calendar picker, and confirmation sheets remain complete in every usable region.

### Additional checks from the second pass

- Drag a dish from the library pane toward a day card and fold the device mid-drag. The session ends cleanly, nothing is planned twice, and nothing is planned into the wrong slot.
- In a book pose, confirm no meal slot, day card, or drop target overlaps the active folding region, and that a day card is never split across it.
- Cook with a running timer on the outer display and confirm the expanded Dynamic Island never covers the step header or controls.
- Fold during cooking and verify there is no repeated narration, no duplicated timer, no resume prompt, and no change to the step index.
- Start the recipe scanner on the inner display and confirm overlays move aside as the inner camera region appears.
- Open the device with the shopping add field focused mid-word. Keyboard, text, and caret survive.
- Verify the dish search field stays with the dish pane and the calendar’s own controls stay above the calendar once both are visible.
- Evaluate the bar-free cooking view against the bar-carrying one on a real worktop at arm’s length before committing to either.

## Technology-overview refinements (2026-09-19)

The newer overview distinguishes bars by their host. In a multi-column plan/library split view, sidebar/content bars remain horizontal while the detail bar can be vertical; inspector bars remain horizontal. A recipe, scanner, or shopping sheet on the outer display defaults to a vertical bar. On the inner display, centered/leading sheets use horizontal bars and trailing sheets use vertical ones. Test real sheet placement; use `presentationPlacement(_:)` to choose a placement and `toolbarVerticalBehavior(_:)` only for a justified sheet exception. Custom cooking chrome can read `toolbarVerticalEdge` instead of guessing from aspect ratio.

For plan, cooking, and shopping commands, provide icon plus title. The overview says title-only and custom-view toolbar items do not appear vertically. Put Close in `.cancellationAction`, a prominent Done/Save in `.topBarPinnedTrailing`, use `axisBehavior(_:)` and `visibilityPriority(_:)` to control inclusion and overflow order, and put infrequent print/export/setup actions in `ToolbarOverflowMenu`. A recipe image can extend beneath a vertical bar via `backgroundExtensionEffect()`; ingredients, step text, timers, and controls stay inset.

Apple cautions that nesting an `ArrangementView` in a navigation split view, `List`, or `ScrollView` can hide a child. For the calendar/dish and instruction/ingredients pairs, arrange the peer views at a content root with the scrolling lists inside the children; verify both remain reachable in every fold state. If the split-view detail host constrains an arrangement, retain the existing adaptive panes and apply reserved-region geometry there. Use split style for the two working panes, including top/bottom in tall space; use `.split.axes(.horizontal)` only if hiding the secondary pane in tall space still leaves its function reachable. If recipe scanning uses AVFoundation or AVKit, choose the camera by facing direction and reassess when opening, closing, or rotating. Exercise the scanner, cooking sheet, dish picker, shopping popovers, and timer Live Activity in each rotated pose.

## Sources

- [Preparing your app for iPhone Duo — Technology Overview](https://developer.apple.com/documentation/technologyoverviews/preparing-your-app-for-iphone-duo)
- [Designing for iPhone Duo — Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/designing-for-iphone-duo)
- [iPhone Duo technical specifications](https://www.apple.com/iphone-duo/specs/)
- [Prepare your app for iPhone Duo](https://developer.apple.com/videos/play/tech-talks/111461/)
- [Design for iPhone Duo](https://developer.apple.com/videos/play/tech-talks/111466/)
- [Strike a pose with adaptive layouts on iPhone Duo](https://developer.apple.com/videos/play/tech-talks/111463/)
- [Raise the bar with iPhone Duo](https://developer.apple.com/videos/play/tech-talks/111462/)
- [Leverage multiple displays and scenes on iPhone Duo](https://developer.apple.com/videos/play/tech-talks/111464/)
