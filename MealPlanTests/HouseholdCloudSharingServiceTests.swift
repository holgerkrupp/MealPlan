import Testing
import Foundation
@testable import MealPlan

/// `isShareURL` decides whether a URL that reached the app through
/// `onOpenURL` (rather than the system's own CloudKit acceptance sheet)
/// should still be treated as a household invitation. See
/// `AppState.handle(openedURL:)`.
struct HouseholdCloudSharingServiceTests {

    @Test func recognizesICloudShareLinks() {
        #expect(HouseholdCloudSharingService.isShareURL(URL(string: "https://www.icloud.com/share/abc123")!))
        #expect(HouseholdCloudSharingService.isShareURL(URL(string: "https://icloud.com/share/abc123")!))
    }

    @Test func ignoresUnrelatedLinks() {
        #expect(!HouseholdCloudSharingService.isShareURL(URL(string: "mealplan://today")!))
        #expect(!HouseholdCloudSharingService.isShareURL(URL(string: "https://www.icloud.com/settings")!))
        #expect(!HouseholdCloudSharingService.isShareURL(URL(string: "https://example.com/share/abc123")!))
    }
}
