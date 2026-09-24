import os

enum RecipePerformanceSignposts {
    static let signposter = OSSignposter(
        subsystem: "de.holgerkrupp.mealplan",
        category: "recipe discovery"
    )
}
