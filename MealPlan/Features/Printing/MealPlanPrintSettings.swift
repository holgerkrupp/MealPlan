import Foundation

/// Which days a printout covers.
///
/// Everything except `.custom` is relative, and that is the point: someone who
/// prints the coming week every Sunday should be able to reopen the sheet and
/// hit print, not re-pick two dates. `.custom` is the escape hatch — pick any
/// start and end — and only its *length* is remembered, since a start date
/// saved in April is worse than useless in May.
enum PrintSpan: String, CaseIterable, Identifiable, Codable, Sendable {
    /// The week the planner is currently looking at.
    case shownWeek
    /// The week after the one the planner is looking at.
    case nextWeek
    case next7Days
    case next14Days
    case next30Days
    case custom

    var id: String { rawValue }

    var localizedName: String {
        switch self {
        case .shownWeek: String(localized: "The week shown")
        case .nextWeek: String(localized: "Next week")
        case .next7Days: String(localized: "The next 7 days")
        case .next14Days: String(localized: "The next 14 days")
        case .next30Days: String(localized: "The next 30 days")
        case .custom: String(localized: "Custom dates")
        }
    }

    /// Resolve to a half-open day range.
    ///
    /// - Parameters:
    ///   - reference: the week the planner is showing, for the two week spans.
    ///   - today: where the rolling spans start.
    ///   - customStart / customDayCount: used by `.custom` only.
    func range(
        reference: Date,
        today: Date = .now,
        customStart: Date = .now,
        customDayCount: Int = MealPlanPrintSettings.defaultCustomDayCount
    ) -> DayRange {
        switch self {
        case .shownWeek:
            let start = reference.startOfWeek()
            return DayRange(start: start, end: start.adding(weeks: 1))
        case .nextWeek:
            let start = reference.startOfWeek().adding(weeks: 1)
            return DayRange(start: start, end: start.adding(weeks: 1))
        case .next7Days:
            return DayRange(start: today.startOfDay, end: today.startOfDay.adding(days: 7))
        case .next14Days:
            return DayRange(start: today.startOfDay, end: today.startOfDay.adding(days: 14))
        case .next30Days:
            return DayRange(start: today.startOfDay, end: today.startOfDay.adding(days: 30))
        case .custom:
            let start = customStart.startOfDay
            let days = MealPlanPrintSettings.clampedDayCount(customDayCount)
            return DayRange(start: start, end: start.adding(days: days))
        }
    }
}

/// What a printout is of.
///
/// One picker rather than two switches: "neither" is not a printout, and the
/// two things are read in different places anyway — the plan goes on the
/// fridge door, the list goes in a coat pocket.
enum PrintContent: String, CaseIterable, Identifiable, Codable, Sendable {
    case plan
    case shoppingList
    case planAndShoppingList

    var id: String { rawValue }

    var includesPlan: Bool { self != .shoppingList }
    var includesShoppingList: Bool { self != .plan }

    var localizedName: String {
        switch self {
        case .plan: String(localized: "Meal plan")
        case .shoppingList: String(localized: "Shopping list")
        case .planAndShoppingList: String(localized: "Plan and shopping list")
        }
    }
}

/// How much nutrition a printout carries.
///
/// Separate switches rather than one "detail level" because the three answer
/// different questions: a per-meal figure helps while cooking, a per-day one
/// while planning, and the summary is what you look at after the week is over.
/// All three are ignored outright when the household has estimates switched
/// off in Settings — see `Household.showsNutritionEstimates`.
struct PrintNutritionOptions: Codable, Equatable, Sendable {
    var perMeal: Bool = false
    var perDay: Bool = true
    var summary: Bool = false
    /// Protein / carbs / fat next to the energy figure, wherever one appears.
    var macros: Bool = false

    static let none = PrintNutritionOptions(perMeal: false, perDay: false, summary: false, macros: false)

    var isAnythingOn: Bool { perMeal || perDay || summary }
}

/// Everything the print sheet remembers between sessions.
///
/// Stored as one JSON blob in `UserDefaults` rather than a scattering of
/// `@AppStorage` keys: it is read and written in exactly one place, it stays
/// one atomic value to hand to the renderer, and adding an option later
/// doesn't need a migration — a missing key simply keeps its default.
struct MealPlanPrintSettings: Codable, Equatable, Sendable {
    var content: PrintContent = .plan
    var paper: PaperSize = .a4
    var orientation: PrintOrientation = .landscape
    var span: PrintSpan = .shownWeek
    /// Length of a `.custom` span, in days. The start date is picked afresh
    /// each time; see `PrintSpan`.
    var customDayCount: Int = MealPlanPrintSettings.defaultCustomDayCount
    var nutrition = PrintNutritionOptions()
    /// Meal notes ("double batch", "Anna's birthday") under the dish name.
    var showsNotes: Bool = true
    /// Draw a meal's row even on days nothing is planned in it. Off makes a
    /// half-planned week compact; on keeps the grid honest and writable-in
    /// with a pen, which is what a printed plan is usually for.
    var showsEmptyMeals: Bool = true
    /// Squeeze the whole span onto a single sheet, shrinking the type, as long
    /// as the columns stay readable. On by default: a plan for the fridge door
    /// is one sheet, and someone who wants roomier columns can say so.
    var fitsOnOnePage: Bool = true

    static let defaultCustomDayCount = 7
    static let dayCountRange = 1...92

    static func clampedDayCount(_ value: Int) -> Int {
        min(max(value, dayCountRange.lowerBound), dayCountRange.upperBound)
    }

    // MARK: - Persistence

    static let defaultsKey = "print.planSettings"

    /// The stored settings, or the defaults when nothing has been printed yet
    /// or the stored blob no longer decodes (an option removed in a later
    /// version). A print sheet that opens with sane defaults beats one that
    /// refuses to open.
    /// The shopping list is printed as it stands on the Shopping screen, so
    /// the day options only mean anything when a plan is being printed too.
    var showsDayOptions: Bool { content.includesPlan }

    static func load(from defaults: UserDefaults = .standard) -> MealPlanPrintSettings {
        guard let data = defaults.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode(MealPlanPrintSettings.self, from: data)
        else { return MealPlanPrintSettings() }
        var settings = decoded
        settings.customDayCount = clampedDayCount(decoded.customDayCount)
        return settings
    }

    func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
