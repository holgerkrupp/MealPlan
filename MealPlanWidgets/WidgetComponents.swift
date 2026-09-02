import SwiftUI
import WidgetKit
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Dish tile

/// The square in front of a meal: its photo when it has one, otherwise the
/// dish's own emoji / symbol placeholder on a tint derived from its name —
/// the same placeholder the dish grid uses in the app.
struct MealTile: View {
    var meal: WidgetMeal
    var size: CGFloat

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: max(4, size * 0.24), style: .continuous)
    }

    var body: some View {
        if let data = meal.thumbnail, let image = Image(widgetData: data) {
            image
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(shape)
        } else {
            let tint = DishGlyph.tint(forName: meal.title)
            glyph(tint: tint)
                .frame(width: size, height: size)
                .background(tint.opacity(0.18), in: shape)
        }
    }

    @ViewBuilder
    private func glyph(tint: Color) -> some View {
        switch meal.glyph {
        case .emoji(let value):
            Text(value)
                .font(.system(size: size * 0.55))
                .minimumScaleFactor(0.5)
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: size * 0.44))
                .foregroundStyle(tint)
        case nil:
            Image(systemName: meal.fallbackSymbol)
                .font(.system(size: size * 0.4))
                .foregroundStyle(tint)
        }
    }
}

// MARK: - Rows

/// A meal on its own line: tile, the meal it belongs to, and the dish.
struct MealRow: View {
    var meal: WidgetMeal
    var tileSize: CGFloat = 26
    var titleFont: Font = .caption
    var slotFont: Font = .system(size: 9, weight: .semibold)
    /// Overrides the meal name on the top line — the upcoming widget puts the
    /// day there instead ("Thu · Dinner").
    var slotText: String?

    var body: some View {
        HStack(spacing: 7) {
            MealTile(meal: meal, size: tileSize)
            VStack(alignment: .leading, spacing: 1) {
                Text(slotText ?? meal.slotName)
                    .font(slotFont)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(meal.title)
                    .font(titleFont)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Chrome

/// The small caption above a widget's content, e.g. "Today · Mon 1 Sep".
struct WidgetHeader: View {
    var title: String
    var subtitle: String?
    var symbol: String?

    var body: some View {
        HStack(spacing: 4) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
            }
            Text(title)
                .font(.caption.weight(.semibold))
            if let subtitle {
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
}

/// Shown wherever there is nothing planned, in place of an empty list.
struct NothingPlannedNote: View {
    var text: String = String(localized: "Nothing planned yet")
    var compact: Bool = false

    var body: some View {
        VStack(spacing: 4) {
            if !compact {
                Image(systemName: "calendar.badge.plus")
                    .font(.title3)
                    .foregroundStyle(.tertiary)
            }
            Text(text)
                .font(compact ? .caption2 : .footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Helpers

extension Image {
    init?(widgetData data: Data) {
        #if canImport(UIKit)
        guard let ui = UIImage(data: data) else { return nil }
        self.init(uiImage: ui)
        #else
        return nil
        #endif
    }
}

extension Date {
    /// "Mon 1 Sep", localized.
    var widgetDayLabel: String {
        formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }

    /// "1 Sep", localized — used for the ends of a week range.
    var widgetShortDayLabel: String {
        formatted(.dateTime.day().month(.abbreviated))
    }
}


// MARK: - Previews

private func previewMeal(_ slot: String, _ title: String, _ emoji: String?) -> WidgetMeal {
    WidgetMeal(
        id: UUID(),
        slotName: slot,
        slotSymbol: "fork.knife",
        title: title,
        thumbnail: nil,
        glyphRaw: emoji.map { DishGlyph.emoji($0).rawValue }
    )
}

#Preview("Tiles") {
    HStack(spacing: 10) {
        MealTile(meal: previewMeal("Dinner", "Spaghetti Bolognese", "🍝"), size: 44)
        MealTile(meal: previewMeal("Lunch", "Kürbissuppe", nil), size: 44)
        MealTile(meal: previewMeal("Dinner", "Trattoria da Vinci", nil), size: 44)
        MealTile(meal: previewMeal("Breakfast", "Porridge", "🥣"), size: 22)
    }
    .padding()
}

#Preview("Rows and chrome") {
    VStack(alignment: .leading, spacing: 10) {
        WidgetHeader(title: "Today", subtitle: "Mon 1 Sep", symbol: "calendar")
        MealRow(meal: previewMeal("Breakfast", "Porridge", "🥣"))
        MealRow(meal: previewMeal("Dinner", "Spaghetti Bolognese", "🍝"), tileSize: 42, titleFont: .subheadline)
        MealRow(meal: previewMeal("Lunch", "Linsensalat", "🥗"), slotText: "Thu · Lunch")
        NothingPlannedNote()
            .frame(height: 60)
    }
    .padding()
    .frame(width: 340)
}
