import SwiftUI

/// The next planned dishes, a fortnight ahead.
///
/// Days with nothing on them are dropped rather than shown empty: on a screen
/// this size a run of blank days would push the next real meal out of sight,
/// which is the one thing this screen exists to show.
struct WatchPlanView: View {

    @Environment(WatchDataStore.self) private var store

    private var days: [WatchDay] { store.snapshot.plannedDays() }

    var body: some View {
        Group {
            if days.isEmpty {
                WatchEmptyState(
                    symbol: "calendar",
                    title: String(localized: "Nothing planned"),
                    message: String(localized: "Meals you plan on iPhone show up here.")
                )
            } else {
                List {
                    ForEach(days) { day in
                        Section {
                            ForEach(day.meals) { meal in
                                NavigationLink {
                                    WatchMealDetailView(day: day, meal: meal)
                                } label: {
                                    WatchMealRow(meal: meal)
                                }
                            }
                        } header: {
                            WatchDayHeader(date: day.date)
                        }
                    }
                    WatchSyncFooter()
                }
            }
        }
        .navigationTitle(String(localized: "Plan"))
    }
}

// MARK: - Rows

/// A day's heading: "Today", "Tomorrow", then the weekday and date.
struct WatchDayHeader: View {

    var date: Date

    var body: some View {
        HStack(spacing: 4) {
            Text(name)
            Text(date.formatted(.dateTime.day().month(.abbreviated)))
                .foregroundStyle(.tertiary)
        }
    }

    private var name: String {
        let calendar = Calendar.current
        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: .now),
            to: calendar.startOfDay(for: date)
        ).day ?? 0
        switch days {
        case 0: return String(localized: "Today")
        case 1: return String(localized: "Tomorrow")
        default: return date.formatted(.dateTime.weekday(.wide))
        }
    }
}

/// One planned meal: its picture stand-in, its name, and which meal it is.
struct WatchMealRow: View {

    var meal: WatchMeal

    var body: some View {
        HStack(spacing: 8) {
            WatchDishGlyph(meal: meal)
            VStack(alignment: .leading, spacing: 1) {
                // A recipe name is never shortened — see the phone app's rule
                // about this; a truncated dish name is a dish you can't
                // recognise.
                Text(meal.title)
                    .font(.body)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                Label(meal.mealName, systemImage: meal.mealSymbol)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// The dish's emoji or symbol on its tinted disc — the same stand-in the phone
/// shows when a dish has no photo. Photos themselves are left on the phone:
/// they would dominate a transfer that has to stay small.
struct WatchDishGlyph: View {

    var meal: WatchMeal

    private var tint: Color { WatchGlyphTint.color(forName: meal.title) }

    var body: some View {
        ZStack {
            Circle().fill(tint.opacity(0.25))
            if let emoji = meal.emoji {
                Text(emoji).font(.system(size: 17))
            } else {
                Image(systemName: meal.symbolName ?? meal.fallbackSymbol)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(tint)
            }
        }
        .frame(width: 30, height: 30)
        .accessibilityHidden(true)
    }
}

/// The phone derives a dish's placeholder colour from its name (djb2) so it is
/// the same on every device without storing anything. Same palette, same hash,
/// so a dish looks the same on the wrist as in your hand.
enum WatchGlyphTint {

    static let palette: [Color] = [
        .orange, .blue, .green, .purple, .pink, .teal, .indigo, .brown, .mint, .red,
    ]

    static func color(forName name: String) -> Color {
        guard !name.isEmpty else { return .gray }
        var hash: UInt64 = 5381
        for byte in name.utf8 { hash = (hash &* 33) ^ UInt64(byte) }
        return palette[Int(hash % UInt64(palette.count))]
    }
}
