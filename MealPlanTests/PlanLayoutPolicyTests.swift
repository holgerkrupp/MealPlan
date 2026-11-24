import Testing
import SwiftUI
@testable import MealPlan

struct PlanLayoutPolicyTests {
    @Test func compactLandscapePhoneOffersDishSidebar() {
        #expect(PlanLayoutPolicy.supportsDishSidebar(
            in: CGSize(width: 812, height: 375),
            horizontalSizeClass: .compact
        ))
    }

    @Test func smallestSupportedLandscapePhoneStillOffersDishSidebar() {
        #expect(PlanLayoutPolicy.supportsDishSidebar(
            in: CGSize(width: 667, height: 375),
            horizontalSizeClass: .compact
        ))
    }

    @Test func compactPortraitPhoneKeepsSingleColumnPlan() {
        #expect(!PlanLayoutPolicy.supportsDishSidebar(
            in: CGSize(width: 440, height: 956),
            horizontalSizeClass: .compact
        ))
    }

    @Test func narrowRegularWindowKeepsSingleColumnPlan() {
        #expect(!PlanLayoutPolicy.supportsDishSidebar(
            in: CGSize(width: 650, height: 900),
            horizontalSizeClass: .regular
        ))
    }

    @Test func sidebarLeavesEnoughRoomForCalendarOnSmallPhone() {
        #expect(PlanLayoutPolicy.sidebarWidth(preferred: 300, availableWidth: 667) == 277)
    }

    @Test func rememberedSidebarWidthIsUsedWhenItFits() {
        #expect(PlanLayoutPolicy.sidebarWidth(preferred: 340, availableWidth: 900) == 340)
    }

    @Test func resizingUsesDragTranslationWithoutExceedingBounds() {
        #expect(PlanLayoutPolicy.resizingSidebarWidth(
            startingAt: 300,
            translation: -100,
            availableWidth: 900
        ) == 400)
        #expect(PlanLayoutPolicy.resizingSidebarWidth(
            startingAt: 300,
            translation: 200,
            availableWidth: 900
        ) == PlanLayoutPolicy.minimumSidebarWidth)
        #expect(PlanLayoutPolicy.resizingSidebarWidth(
            startingAt: 300,
            translation: -300,
            availableWidth: 700
        ) == 310)
    }
}
