import Foundation
import SwiftData
import WidgetKit

// MARK: - Flattened plan

/// One planned meal, flattened out of SwiftData. Timeline entries are archived
/// by the system, so nothing here may hold on to a `ModelContext` or a model.
struct WidgetMeal: Identifiable, Hashable {
    var id: UUID
    var slotName: String
    var slotSymbol: String
    var title: String
    /// A small JPEG, already scaled down to fit the widget's memory budget.
    /// `nil` when the dish has no photo, or when the budget ran out.
    var thumbnail: Data?
    var glyphRaw: String?
    var isEatingOut: Bool = false

    var glyph: DishGlyph? { glyphRaw.flatMap(DishGlyph.init(rawValue:)) }

    /// The symbol shown when there is neither a photo nor a dish glyph.
    var fallbackSymbol: String { isEatingOut ? "takeoutbag.and.cup.and.straw" : "fork.knife" }
}

/// One calendar day of the plan. Days with nothing planned are kept, so the
/// week views can lay out a full grid instead of collapsing.
struct WidgetDay: Identifiable, Hashable {
    var date: Date
    var meals: [WidgetMeal] = []

    var id: Date { date }
    var isEmpty: Bool { meals.isEmpty }

    /// "Today" / "Tomorrow" / "Thursday", relative to the moment the entry is
    /// meant to be on screen (not to `Date.now`, which in a widget can be a
    /// good deal later than when the timeline was built).
    func name(relativeTo now: Date) -> String {
        let calendar = Calendar.current
        let days = calendar.dateComponents([.day], from: now.startOfDay, to: date.startOfDay).day ?? 0
        switch days {
        case 0: return String(localized: "Today")
        case 1: return String(localized: "Tomorrow")
        default: return date.formatted(.dateTime.weekday(.wide))
        }
    }

    var shortName: String { date.formatted(.dateTime.weekday(.abbreviated)) }
    var dayNumber: String { date.formatted(.dateTime.day()) }

    func isToday(relativeTo now: Date) -> Bool { date.startOfDay == now.startOfDay }

    /// The meals as one line, e.g. "Spaghetti · Salat".
    var summaryLine: String { meals.map(\.title).joined(separator: " · ") }
}

extension Array where Element == WidgetDay {

    /// Trims a grouped list to what will actually fit: each day costs one row
    /// for its header plus one per meal, and a day is only kept whole — half a
    /// day's meals under a date is worse than stopping a day earlier.
    func trimmed(toRows budget: Int) -> [WidgetDay] {
        var used = 0
        var kept: [WidgetDay] = []
        for day in self {
            let cost = 1 + day.meals.count
            guard used + cost <= budget || kept.isEmpty else { break }
            used += cost
            kept.append(day)
        }
        return kept
    }
}

// MARK: - Timeline entry

/// The single entry type behind every MealPlan widget. `days[0]` is whatever
/// the widget leads with; later days are context (tomorrow's preview, the rest
/// of the week, the days an "upcoming" list runs through).
struct MealPlanWidgetEntry: TimelineEntry {
    var date: Date
    var days: [WidgetDay]
    var link: URL
    /// Labels such as "Today" are resolved against this, so an entry that the
    /// system shows late still reads consistently with the data it carries.
    var reference: Date

    var primary: WidgetDay? { days.first }
    var secondary: WidgetDay? { days.dropFirst().first }

    /// Every planned meal across `days`, in day order, paired with its day.
    var flattened: [(day: WidgetDay, meal: WidgetMeal)] {
        days.flatMap { day in day.meals.map { (day, $0) } }
    }
}

// MARK: - Deep links

enum WidgetLink {
    static let today = DeepLink.today.url

    static func day(_ date: Date) -> URL { DeepLink.date(date).url }
}

// MARK: - Loading

/// Reads the shared store for the widgets. Everything here is synchronous and
/// read-only: a timeline provider gets a few hundred milliseconds and no
/// business writing to a store the app may have open at the same time.
enum WidgetPlanLoader {

    /// How many photos one timeline entry is allowed to decode. A large week
    /// view would otherwise pull a screenful of 1400 px JPEGs into a process
    /// with a hard memory ceiling.
    static let defaultThumbnailBudget = 12

    /// Widget tiles top out around 44 pt, so 132 px covers @3x.
    private static let thumbnailPixels: CGFloat = 132

    private nonisolated(unsafe) static var cachedContainer: ModelContainer?
    private static let containerLock = NSLock()

    /// One container per widget process, shared by every timeline provider in
    /// it — opening the same SQLite file several times over is both slower and
    /// needless.
    private static func makeContext() -> ModelContext? {
        containerLock.lock()
        defer { containerLock.unlock() }
        if cachedContainer == nil { cachedContainer = SharedStore.containerIfAvailable() }
        return cachedContainer.map(ModelContext.init)
    }

    /// Every day in `[start, start + count)`, empty days included, in order.
    static func days(
        from start: Date,
        count: Int,
        thumbnailBudget: Int = defaultThumbnailBudget
    ) -> [WidgetDay] {
        let dayCount = max(count, 1)
        let first = start.startOfDay
        let last = first.adding(days: dayCount)
        let blank = (0..<dayCount).map { WidgetDay(date: first.adding(days: $0)) }

        guard let context = makeContext() else { return blank }

        let descriptor = FetchDescriptor<MealPlanEntry>(
            predicate: #Predicate { $0.date >= first && $0.date < last && $0.skipped == false },
            sortBy: [SortDescriptor(\.date), SortDescriptor(\.sortIndex)]
        )
        guard let entries = try? context.fetch(descriptor), !entries.isEmpty else { return blank }

        let meals = mealTypeLookup(in: context)
        var grouped: [Date: [MealPlanEntry]] = [:]
        for entry in entries {
            grouped[entry.date.startOfDay, default: []].append(entry)
        }

        var budget = max(thumbnailBudget, 0)
        return blank.map { day in
            let sorted = (grouped[day.date] ?? []).sorted {
                (meals.rank($0), $0.sortIndex) < (meals.rank($1), $1.sortIndex)
            }
            return WidgetDay(
                date: day.date,
                meals: sorted.map { entry in
                    let thumbnail = budget > 0 ? scaledThumbnail(for: entry) : nil
                    if thumbnail != nil { budget -= 1 }
                    return WidgetMeal(
                        id: entry.uuid,
                        slotName: meals.name(entry),
                        slotSymbol: meals.symbol(entry),
                        title: entry.displayTitle,
                        thumbnail: thumbnail,
                        glyphRaw: entry.dish?.glyphRaw,
                        isEatingOut: entry.isEatingOut
                    )
                }
            )
        }
    }

    /// The next `limit` planned meals, starting today and looking `window`
    /// days ahead. Days with nothing on them are dropped.
    static func upcoming(
        from start: Date = .now,
        window: Int = 21,
        limit: Int,
        thumbnailBudget: Int = defaultThumbnailBudget
    ) -> [WidgetDay] {
        var remaining = limit
        var result: [WidgetDay] = []
        for day in days(from: start, count: window, thumbnailBudget: thumbnailBudget) where !day.isEmpty {
            guard remaining > 0 else { break }
            let take = Array(day.meals.prefix(remaining))
            remaining -= take.count
            result.append(WidgetDay(date: day.date, meals: take))
        }
        return result
    }

    // MARK: - Meal types

    /// Names, symbols and ordering for the household's configured meals.
    private struct MealTypeLookup {
        var order: [String: Int] = [:]
        var names: [String: String] = [:]
        var symbols: [String: String] = [:]

        /// Unconfigured keys sort after every configured one, in the legacy
        /// breakfast/lunch/dinner/snack order.
        func rank(_ entry: MealPlanEntry) -> Int { order[entry.mealKey] ?? (1_000 + entry.slot.sortOrder) }
        func name(_ entry: MealPlanEntry) -> String { names[entry.mealKey] ?? MealType.legacyName(for: entry.mealKey) }
        func symbol(_ entry: MealPlanEntry) -> String { symbols[entry.mealKey] ?? MealType.legacySymbol(for: entry.mealKey) }
    }

    private static func mealTypeLookup(in context: ModelContext) -> MealTypeLookup {
        let types = (try? context.fetch(FetchDescriptor<MealType>())) ?? []
        var lookup = MealTypeLookup()
        // CloudKit can leave duplicates behind until the app next reconciles
        // them; pick the same survivor `MealType.ensure` would.
        for type in types.sorted(by: { $0.uuid.uuidString < $1.uuid.uuidString })
        where lookup.order[type.key] == nil {
            lookup.order[type.key] = type.sortOrder
            lookup.names[type.key] = type.name
            lookup.symbols[type.key] = type.symbolName
        }
        return lookup
    }

    // MARK: - Images

    private static func scaledThumbnail(for entry: MealPlanEntry) -> Data? {
        guard let data = entry.dish?.primaryImageData, !data.isEmpty else { return nil }
        return ImagePreparation.prepared(from: data, maxDimension: thumbnailPixels, quality: 0.7)
    }
}

// MARK: - Gallery samples

/// What the widget gallery and the redacted placeholder show. Deliberately not
/// read from the store: the gallery has to look right before a plan exists.
extension MealPlanWidgetEntry {

    private static func sampleMeal(_ slot: String, _ title: String, _ emoji: String) -> WidgetMeal {
        WidgetMeal(
            id: UUID(),
            slotName: slot,
            slotSymbol: "fork.knife",
            title: title,
            thumbnail: nil,
            glyphRaw: DishGlyph.emoji(emoji).rawValue
        )
    }

    private static var sampleDays: [WidgetDay] {
        let breakfast = String(localized: "Breakfast")
        let lunch = String(localized: "Lunch")
        let dinner = String(localized: "Dinner")
        let start = Date.now.startOfDay
        return [
            WidgetDay(date: start, meals: [
                sampleMeal(breakfast, "Porridge", "🥣"),
                sampleMeal(lunch, "Kürbissuppe", "🎃"),
                sampleMeal(dinner, "Spaghetti Bolognese", "🍝"),
            ]),
            WidgetDay(date: start.adding(days: 1), meals: [
                sampleMeal(lunch, "Linsensalat", "🥗"),
                sampleMeal(dinner, "Ofengemüse", "🍆"),
            ]),
            WidgetDay(date: start.adding(days: 2), meals: [
                sampleMeal(dinner, "Pfannkuchen", "🥞"),
            ]),
            WidgetDay(date: start.adding(days: 3), meals: []),
            WidgetDay(date: start.adding(days: 4), meals: [
                sampleMeal(dinner, "Pizza", "🍕"),
            ]),
            WidgetDay(date: start.adding(days: 5), meals: [
                sampleMeal(lunch, "Reste", "🍲"),
                sampleMeal(dinner, "Chili sin Carne", "🌶️"),
            ]),
            WidgetDay(date: start.adding(days: 6), meals: [
                sampleMeal(dinner, "Burger", "🍔"),
            ]),
        ]
    }

    /// A sample anchored on today, for the day-oriented widgets.
    static var sample: MealPlanWidgetEntry {
        MealPlanWidgetEntry(date: .now, days: sampleDays, link: WidgetLink.today, reference: .now)
    }

    /// A sample anchored on the start of this week, for the week widget.
    static var sampleWeek: MealPlanWidgetEntry {
        let start = Date.now.startOfWeek()
        let days = sampleDays.enumerated().map { WidgetDay(date: start.adding(days: $0.offset), meals: $0.element.meals) }
        return MealPlanWidgetEntry(date: .now, days: days, link: WidgetLink.today, reference: .now)
    }

    /// A sample with the empty days dropped, for the upcoming widget.
    static var sampleUpcoming: MealPlanWidgetEntry {
        MealPlanWidgetEntry(date: .now, days: sampleDays.filter { !$0.isEmpty }, link: WidgetLink.today, reference: .now)
    }

    /// Nothing planned — the state every family sees on their first day.
    static var sampleEmpty: MealPlanWidgetEntry {
        let start = Date.now.startOfDay
        return MealPlanWidgetEntry(
            date: .now,
            days: (0..<7).map { WidgetDay(date: start.adding(days: $0)) },
            link: WidgetLink.today,
            reference: .now
        )
    }
}
