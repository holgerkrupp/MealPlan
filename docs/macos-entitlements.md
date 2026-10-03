# macOS entitlements

The `MealPlan` target uses `MealPlan/MealPlan-macOS.entitlements` when building
with the macOS SDK. Other platforms use `MealPlan/MealPlan.entitlements`.
Keeping the files separate prevents iPhone- or iPad-only capabilities from
being inherited by the Mac App Store product.

## Entitlement-to-feature map

| Entitlement | macOS feature that requires it |
| --- | --- |
| `com.apple.security.app-sandbox` | Required for Mac App Store distribution. |
| `com.apple.security.application-groups` | Shares the SwiftData store, cached recipe articles, cooking-session defaults, and widget reload state through `group.de.holgerkrupp.mealplan`. |
| `com.apple.developer.icloud-container-identifiers` | Selects `iCloud.de.holgerkrupp.mealplan` for household data and sharing. |
| `com.apple.developer.icloud-services` | Enables the CloudKit-backed household sync and sharing services. |
| `com.apple.developer.ubiquity-kvstore-identifier` | Keeps the app's iCloud key-value store identity stable. |
| `com.apple.developer.aps-environment` | Receives silent CloudKit change notifications; the macOS app delegate registers for remote notifications and refreshes household records. |
| `com.apple.security.network.client` | Fetches recipe feeds, linked recipe pages and images, and performs restaurant searches. |
| `com.apple.security.files.user-selected.read-write` | Imports recipes, PDFs, and backups selected by the user and exports recipes, backups, and meal-plan PDFs. |
| `com.apple.security.personal-information.calendars` | Reads opted-in calendars for planning context and publishes meal-plan events through EventKit. The Reminders exporter also uses EventKit. |
| `com.apple.security.personal-information.location` | Optionally centres restaurant results near the user through `CLLocationUpdate`; restaurant search still works if permission is declined. |
| `com.apple.security.device.audio-input` | Cooking Mode's opt-in hands-free voice control records short microphone segments with `AVAudioEngine` for on-device `SFSpeechRecognizer` commands. |

The Mac app intentionally has no Camera or Photos Library entitlement. Camera
capture and document scanning are compiled only for iOS. Mac photo selection
uses `PhotosPicker`, which grants access only to the items the user selects and
does not require broad Photos-library access. iOS camera access remains governed
by `NSCameraUsageDescription` and the system camera picker.

## Release verification

After archiving or exporting the macOS app, inspect the entitlements embedded
in the signed product rather than relying only on the source plist:

```sh
scripts/verify-macos-entitlements.sh /path/to/MealPlan.app
```

The check fails if the signed app has Camera or broad Photos-library access, or
if any entitlement required by the Mac features above is missing.
