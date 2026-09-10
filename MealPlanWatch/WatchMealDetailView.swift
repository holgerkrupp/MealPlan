import SwiftUI

/// What is known about one planned meal. There is no recipe here on purpose:
/// steps and ingredients belong on a screen you can read while cooking, and
/// this one is for "what are we having, and for how many".
struct WatchMealDetailView: View {

    var day: WatchDay
    var meal: WatchMeal

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    WatchDishGlyph(meal: meal)
                    VStack(alignment: .leading, spacing: 1) {
                        Label(meal.mealName, systemImage: meal.mealSymbol)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        WatchDayHeader(date: day.date)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }

                Text(meal.title)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)

                if meal.isEatingOut, let place = meal.placeName, place != meal.title {
                    Label(place, systemImage: "mappin.and.ellipse")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if let servings = meal.servings {
                    Label(
                        String(localized: "For \(servings)"),
                        systemImage: "person.2"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }

                if let note = meal.note {
                    Divider()
                    Text(note)
                        .font(.footnote)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 2)
        }
        .navigationTitle(meal.mealName)
        .navigationBarTitleDisplayMode(.inline)
    }
}
