import Testing
import SwiftUI
@testable import MealPlan

struct LandscapeLayoutTests {
    @Test func cookingUsesTwoColumnsOnLandscapePhone() {
        #expect(CookingModeLayoutPolicy.usesSideBySideLayout(
            in: CGSize(width: 812, height: 375)
        ))
    }

    @Test func cookingKeepsPortraitPhoneSingleColumn() {
        #expect(!CookingModeLayoutPolicy.usesSideBySideLayout(
            in: CGSize(width: 390, height: 844)
        ))
    }

    @Test func cookingUsesBothPanesForWideRegularWindow() {
        #expect(CookingModeLayoutPolicy.usesSideBySideLayout(
            in: CGSize(width: 1_024, height: 768)
        ))
    }

    @Test func cookingStacksAtAccessibilityTextSizes() {
        #expect(!CookingModeLayoutPolicy.usesSideBySideLayout(
            in: CGSize(width: 1_200, height: 800),
            dynamicTypeSize: .accessibility1
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
