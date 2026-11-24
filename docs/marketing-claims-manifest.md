# Meals positioning and claim evidence

Status: prepared for publication; not a release-build sign-off.  
Research date: 2026-11-24 (Europe/Berlin).  
Owner: Meals/MealPlan maintainers.

This document is the evidence manifest for App Store and product-page copy. It keeps competitor facts dated and country-specific. Recheck every price, entitlement, and release-build behavior immediately before publishing.

## Product copy

### English App Store copy

**Promotional text**

Plan meals with your household, keep your recipes close, and cook with an Apple-native app—without a subscription.

**Short description**

Collect recipes, scan and import, shop from your plan, and sync with iCloud. Plan today plus seven days free; unlock unlimited advance planning with one purchase.

**Feature copy**

Meals gives you a generous recipe library, recipe collections, saved searches, pantry-aware groceries, recipe scanning, pasted-text import, household collaboration, and Apple-platform integrations. The free plan covers today and the next seven days. A single non-consumable purchase removes that advance-planning limit; it does not create a subscription.

### German App Store copy

**Werbetext**

Gemeinsam planen, Rezepte sammeln und entspannt kochen – ohne Abo.

**Kurzbeschreibung**

Rezepte sammeln, scannen und importieren, aus dem Plan einkaufen und per iCloud synchronisieren. Heute plus sieben Tage kostenlos planen; mit einem einmaligen Kauf unbegrenzt vorausplanen.

**Feature-Text**

Meals bietet eine großzügige Rezeptsammlung, Sammlungen, gespeicherte Suchen, vorratsbewusste Einkaufslisten, Rezeptscan, Import aus kopiertem Text, Haushaltszusammenarbeit und native Apple-Integrationen. Der kostenlose Plan umfasst heute und die nächsten sieben Tage. Ein einmaliger In-App-Kauf entfernt diese Grenze für die Vorausplanung; es gibt kein Abonnement.

## Website-ready comparison

| Capability | Meals Free | Meals — Unlimited Planning | Paprika 4 Free (new users) | Paprika Standard (legacy purchasers) | Paprika Premium |
| --- | --- | --- | --- | --- | --- |
| Recipe count | No product-count gate is documented; verify with release fixtures | Same | 50 recipes | Unlimited | Unlimited |
| Planning horizon | Today plus seven days ahead | Unlimited advance planning | Basic planning advertised; verify current details | Basic planning advertised; verify current details | Basic planning advertised; verify current details |
| Sync and household sharing | iCloud/CloudKit household workflow, subject to Apple account and device validation | Same | Not included in the audited comparison | Included for eligible legacy purchasers | Included |
| Recipe scan and pasted-text extraction | Included where supported by the device/workflow; verify release build | Same | Not included in the audited comparison | Not included in the audited comparison | Included |
| Barcode and nutrition | Barcode scan with local/manual fallback; nutrition is estimated or imported and may be incomplete | Same | Not claimed | Not claimed | Paprika Premium claims its own analysis; this is not an equivalence claim |
| Cost model | Free | One non-consumable purchase; no subscription | Free tier | Existing entitlement for prior purchasers | Subscription tier |

The table intentionally says “not claimed” where the source comparison does not establish a capability. Meals should be described as Apple-native (iPhone, iPad, Mac, Apple Watch, and related existing targets), not as an Android or Windows product.

## Evidence manifest

Classification:

- **Verified in source/code**: implementation evidence exists, but release/device QA may still be required.
- **Conditional**: depends on permissions, supported content, network, locale, device, or a release-build check.
- **Awaiting release verification**: do not publish as an unconditional claim until #144 records the result.
- **Unsupported**: do not use in marketing.

| Claim | Classification | Evidence | Required check before publication |
| --- | --- | --- | --- |
| No subscription; one-time unlock | Verified in source/code | `MealPlan/Store/PurchaseManager.swift`, `MealPlan/Store/PaywallView.swift` | Confirm current regional StoreKit product and wording on a signed build |
| Free planning is today plus seven days ahead | Verified in source/code | `MealPlanShared/Support/PlanningAccess.swift` | Confirm clean free entitlement and boundary dates on signed builds |
| No recipe-count paywall | Conditional | Existing Dishes/import/collection paths; no recipe-count gate found in the entitlement path | Test 50, 405, and 1,000+ recipe fixtures; record in #144 |
| iCloud sync and household collaboration | Conditional | `MealPlanShared/Support/SharedModelContainer.swift`, CloudKit collaboration services, `docs/icloud-sharing.md` | Two-account signed-device join, edit, offline, view-only, and recovery matrix in #144 |
| Recipe scanning and pasted-text import | Conditional | `RecipeScannerView`, `DocumentScanner`, `RecipeTextScanner`, `PasteRecipeSheet`, `RecipeExtractor` | Device permissions, localization, Share Extension, and representative input checks in #144 |
| Social recipe import | Conditional | `SocialRecipeImporter`, Share Extension flows from #154/#155 | Live public URL and blocked/authenticated content matrix in #144; never promise universal extraction |
| Barcode scanning | Conditional | `BarcodeAddSheet`, VisionKit barcode path, `BarcodeProductMemory` | Real barcode/offline/manual fallback coverage in #144; do not imply worldwide product identification |
| Nutrition estimates | Conditional | `MealPlanShared/Nutrition/NutritionEstimator.swift`, `NutritionLabel.swift` | Locale/unit/unknown-value checks in #144; never describe estimates as medical advice or guaranteed USDA analysis |
| Pantry-aware groceries | Conditional | `PantryInventory`, `ShoppingListBuilder`, Pantry UI | Large-library and household-sync validation in #144 |
| Apple-native platform integration | Verified in source/code | Existing iPhone/iPad/Mac/Watch/widget targets and entitlements | Signed platform matrix in #144 |
| Unlimited separate shopping lists | Unsupported unless #164 is shipped and verified | Current single generated list behavior is not proof of this claim | Do not use until named-list implementation and sync QA are complete |
| Watch cooking companion parity | Awaiting release verification | #162 implementation, once merged | Paired Watch handoff, timers, reconnect, and restoration in #144 |
| Hosted calendar subscription feed | Unsupported | Meals writes to EventKit calendars and can export an `.ics` snapshot; this is not a hosted feed | Never use this wording |
| Android/Windows/Alexa support | Unsupported | Existing targets do not establish these platforms | Never use this wording |

## Paprika source notes

The following are dated research references, not permanent price guarantees:

1. [Paprika 4 official pricing comparison](https://www.paprikaapp.com/help/v4/ios/pricing/) — accessed 2026-11-23; source for Free, legacy Standard, and Premium entitlement distinctions.
2. [Paprika 4 launch announcement](https://www.paprikaapp.com/news/2026/11/06/paprika-4-is-now-available-for-all-users/) — published 2026-11-06; source for the launch and introductory Premium pricing context.
3. [Paprika 4 official feature list](https://www.paprikaapp.com/) — accessed 2026-11-23; source for feature wording only.
4. [Paprika 4 Germany App Store listing](https://apps.apple.com/de/app/paprika-rezept-manager-4/id1303222868) — accessed 2026-11-23; listed Premium price was €17.99/year, with a displayed €9.99/year legacy discount at the audit. Recheck region, eligibility, and period before publication.
5. [Meals Germany App Store listing](https://apps.apple.com/de/app/meals-plan-ahead/id6807839511) — accessed 2026-11-23; listed Unlimited Planning price was €4.99 one time at the audit. Recheck the storefront before using a numeric price.

Paprika has three relevant entitlement groups. Do not call Paprika subscription-only: Standard is the retained entitlement for existing paid customers, while Premium is an optional subscription for the newer tier. Do not present legacy Standard users as limited to 50 recipes.

## Screenshot and release handoff

Screenshot concepts belong to #141 and should show the actual current UI: recipe import/pantry, a household plan, Apple-device sync, scan/paste import, and the free-versus-one-time-planning boundary. Do not put dated competitor prices in static screenshots.

Before publishing any claim, attach the signed-build result to [#144](https://github.com/holgerkrupp/MealPlan/issues/144) with build number, OS, locale, entitlement state, and the tested workflow. Physical-device, CloudKit production, App Store, live social URL, and regional price checks remain release validation—not evidence that can be inferred from this repository document.
