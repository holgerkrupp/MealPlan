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
scripts/verify-macos-entitlements.sh --production /path/to/exported/MealPlan.app
```

The check fails if the signed app has Camera or broad Photos-library access, or
if any entitlement required by the Mac features above is missing.
The production check also verifies the code signature and requires the signed
CloudKit environment to be `Production`, APNs to be `production`, and debugging
to be disabled. Run it on the exported app because Xcode can change entitlements
when it re-signs an archive for distribution.

## Build a Production Mac app without TestFlight

Use the stable Xcode installation and sign in to the Apple Developer team
`46D3VYP253` in Xcode Settings > Accounts. The signing keychain must contain a
`Developer ID Application` identity for that team, including its private key.
Choose My Mac, Product > Archive, then Organizer > Distribute App > Direct
Distribution. Xcode signs and notarizes the exported app for installation
outside the Mac App Store. The archive itself is usually Development signed;
install and verify the exported app instead.

Run `scripts/verify-macos-entitlements.sh --production` on the exported app,
then check it with `spctl --assess --verbose=4 /path/to/MealPlan.app`. Confirm
Settings displays `iCloud environment Production`. A Developer ID export is a
separate distribution route from an App Store or TestFlight upload.
