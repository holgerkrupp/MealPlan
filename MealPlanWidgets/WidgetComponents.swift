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

enum PlanInvitationKind {
    case comingUp
    case today
    case week
}

/// An actual WidgetKit link, styled with the platform's own button treatment.
/// Compact cards omit the supporting sentence to keep small and mixed-day
/// widgets readable.
struct PlanInvitation: View {
    var date: Date
    var kind: PlanInvitationKind = .comingUp
    var compact = false

    private var headline: String {
        switch kind {
        case .comingUp: String(localized: "What's cooking next?", table: "WidgetLocalizable")
        case .today: String(localized: "Fancy planning a meal?", table: "WidgetLocalizable")
        case .week: String(localized: "What's cooking next?", table: "WidgetLocalizable")
        }
    }

    private var supportingText: String {
        switch kind {
        case .comingUp: String(localized: "Find something tasty for the week ahead.", table: "WidgetLocalizable")
        case .today: String(localized: "Plan something for this day.", table: "WidgetLocalizable")
        case .week: String(localized: "Plan something for this week.", table: "WidgetLocalizable")
        }
    }

    private var actionTitle: String {
        compact
            ? String(localized: "Add a meal", table: "WidgetLocalizable")
            : String(localized: "Plan a meal", table: "WidgetLocalizable")
    }

    var body: some View {
        VStack(spacing: compact ? 5 : 8) {
            Image(systemName: "calendar.badge.plus")
                .font(compact ? .title3 : .title2)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text(headline)
                .font(compact ? .caption.weight(.semibold) : .title3.weight(.semibold))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
            if !compact {
                Text(supportingText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            Link(destination: WidgetLink.plan(date)) {
                Label(actionTitle, systemImage: "plus")
                    .font(compact ? .caption.weight(.semibold) : .callout.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(compact ? .small : .regular)
            .accessibilityLabel(Text(verbatim: "\(actionTitle) · \(date.formatted(date: .long, time: .omitted))"))
            .accessibilityHint(Text(supportingText))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .multilineTextAlignment(.center)
    }
}

struct PlanUnavailableNote: View {
    var compact = false

    var body: some View {
        VStack(spacing: compact ? 3 : 6) {
            Image(systemName: "calendar.badge.exclamationmark")
                .font(compact ? .caption : .title3)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(String(localized: "Meal plan unavailable", table: "WidgetLocalizable"))
                .font(compact ? .caption2.weight(.semibold) : .headline)
                .multilineTextAlignment(.center)
                .lineLimit(2)
            if !compact {
                Text(String(localized: "No plan data is available right now.", table: "WidgetLocalizable"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityHint(String(localized: "Open MealPlan to check your plan.", table: "WidgetLocalizable"))
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
    }
    .padding()
    .frame(width: 340)
}
