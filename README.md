# MealPlan

MealPlan is a SwiftUI meal-planning app for Apple platforms. It helps a
household collect recipes, plan meals, keep a shopping list, and share a plan
with other household members.

## Features

- Plan meals on a calendar, including eating out and meal routines.
- Store, edit, search, import, export, and translate recipes.
- Build shopping lists from planned meals and pantry staples.
- Share a household through CloudKit and keep working offline.
- Add meal plans to a calendar and send shopping lists to supported services.
- Use widgets, App Intents, Spotlight, printing, and the recipe share
  extension.

## Requirements

- A Mac with Xcode and the Apple SDKs required by the project.
- An Apple platform supported by the current project settings.
- An iCloud/CloudKit container configured for development or your own
  deployment when testing sync and household sharing.

## Building

Open `MealPlan.xcodeproj` in Xcode, choose the `MealPlan` scheme, select a
destination, and build or run. Some capabilities—such as iCloud sharing,
calendar access, notifications, and StoreKit—need the corresponding entitlements
and development configuration before they can be tested fully.

The project also contains documentation for the recipe archive format and
selected design decisions in [`RECIPE_ARCHIVE_FORMAT.md`](RECIPE_ARCHIVE_FORMAT.md)
and [`docs/`](docs/).

## Licence

This project is source-available for non-commercial use under the
[PolyForm Noncommercial License 1.0.0](LICENSE). You may have, inspect, modify,
and share the source under its terms. The additional
[app-store restriction](APP_STORE_RESTRICTION.md) prohibits submitting,
uploading, publishing, or distributing the project or any build of it through
an app store or similar software marketplace.

PolyForm Noncommercial is source-available but is not an OSI-approved Open
Source licence because it restricts use to non-commercial purposes. Third-party
code and assets remain subject to their own licences.
