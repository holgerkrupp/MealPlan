import Testing
import SwiftUI
@testable import MealPlan

struct LandscapeLayoutTests {
    @Test func cookingUsesTwoColumnsOnLandscapePhone() {
        #expect(CookingModeLayoutPolicy.usesSideBySideLayout(
            in: CGSize(width: 812, height: 375),
            horizontalSizeClass: .compact,
            verticalSizeClass: .compact
        ))
    }

    @Test func cookingKeepsPortraitPhoneSingleColumn() {
        #expect(!CookingModeLayoutPolicy.usesSideBySideLayout(
            in: CGSize(width: 390, height: 844),
            horizontalSizeClass: .compact,
            verticalSizeClass: .regular
        ))
    }

    @Test func cookingDoesNotUsePhoneLayoutForWideRegularWindow() {
        #expect(!CookingModeLayoutPolicy.usesSideBySideLayout(
            in: CGSize(width: 1_024, height: 768),
            horizontalSizeClass: .regular,
            verticalSizeClass: .regular
        ))
    }

    @Test func restaurantMapAndListSplitInLandscape() {
        #expect(EatOutPickerLayoutPolicy.usesSideBySideLayout(
            in: CGSize(width: 812, height: 260)
        ))
    }

    @Test func restaurantMapStacksAboveListInPortrait() {
        #expect(!EatOutPickerLayoutPolicy.usesSideBySideLayout(
            in: CGSize(width: 390, height: 600)
        ))
    }
}
