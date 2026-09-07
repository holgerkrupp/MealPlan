import Foundation
import SwiftData

/// Turns the store into a `MealPlanPrintDocument`.
///
/// The one place in the printing feature that touches SwiftData. Everything
/// downstream — pagination, page views, the PDF — works from the document it
/// returns, so the layout can be exercised without a container (see the note
/// about SwiftData in tests in the build memo).
enum MealPlanPrintBuilder {

    @MainActor
    static func document(
        range: DayRange,
        settings: MealPlanPrintSettings,
        householdName: String,
        energyUnit: EnergyUnit,
        showsNutritionEstimates: Bool,
        context: ModelContext,
        now: Date = .now
    ) -> MealPlanPrintDocument {
        let start = range.start.startOfDay
        let end = range.end.startOfDay
        let entries = settings.content.includesPlan
            ? (try? context.fetch(FetchDescriptor<MealPlanEntry>(
                predicate: #Predicate { $0.date >= start && $0.date < end && $0.skipped == false },
                sortBy: [SortDescriptor(\.date), SortDescriptor(\.sortIndex)]
            ))) ?? []
            : []

        let mealTypes = (try? context.fetch(FetchDescriptor<MealType>(
            sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.name)]
        ))) ?? []

        // The list as it stands on the Shopping screen — printing never
        // rebuilds it, which would silently throw away hand-added lines and
        // every tick.
        let shoppingItems = settings.content.includesShoppingList
            ? (try? context.fetch(FetchDescriptor<ShoppingListItem>(
                sortBy: [SortDescriptor(\.sortIndex)]
            ))) ?? []
            : []

        return document(
            range: range,
            settings: settings,
            householdName: householdName,
            energyUnit: energyUnit,
            showsNutritionEstimates: showsNutritionEstimates,
            mealTypes: MealType.deduplicated(mealTypes).keep,
            entries: entries,
            shoppingItems: shoppingItems,
            now: now
        )
    }

    /// The pure half: everything above, minus the fetch. Split out so it can
    /// be driven from transient model objects.
    @MainActor
    static func document(
        range: DayRange,
        settings: MealPlanPrintSettings,
        householdName: String,
        energyUnit: EnergyUnit,
        showsNutritionEstimates: Bool,
        mealTypes: [MealType],
        entries: [MealPlanEntry],
        shoppingItems: [ShoppingListItem] = [],
        now: Date = .now,
        locale: Locale = .current
    ) -> MealPlanPrintDocument {
        let options = showsNutritionEstimates ? settings.nutrition : .none
        let days = settings.content.includesPlan ? range.days : []
        let entriesByDay = Dictionary(grouping: entries) { $0.date.dayID }
        // Standings compare each day against the middle of everything being
        // printed, so a fortnight is judged against that fortnight.
        let nutrition = options.isAnythingOn ? WeekNutritionSummary(entries: entries) : nil

        let weekdayFormat = Date.FormatStyle.dateTime.weekday(.wide)
        let weekdayShortFormat = Date.FormatStyle.dateTime.weekday(.abbreviated)
        let dateFormat = Date.FormatStyle.dateTime.day().month(.abbreviated)
        let calendar = Calendar.current

        let printedDays: [MealPlanPrintDocument.Day] = days.map { day in
            let dayEntries = entriesByDay[day.dayID] ?? []
            let plannedKeys = Set(dayEntries.map(\.mealKey))
            let meals = DayMeal.forDay(mealTypes: mealTypes, plannedKeys: plannedKeys)
                .map { meal in
                    MealPlanPrintDocument.Meal(
                        id: meal.key,
                        name: meal.name,
                        symbolName: meal.symbolName,
                        entries: dayEntries
                            .filter { $0.mealKey == meal.key }
                            .sorted { $0.sortIndex < $1.sortIndex }
                            .map { entry in
                                printEntry(
                                    entry,
                                    options: options,
                                    unit: energyUnit,
                                    nutrition: nutrition,
                                    showsNotes: settings.showsNotes,
                                    locale: locale
                                )
                            }
                    )
                }
                .filter { settings.showsEmptyMeals || !$0.isEmpty || $0.id == MealType.extraKey }

            // A day whose estimate doesn't hold up prints no figure at all
            // rather than an understated one — see `NutritionEstimate`.
            let facts = options.perDay ? trustworthyFacts(nutrition?.estimate(on: day)) : nil
            let standing = facts == nil ? nil : nutrition?.standing(on: day)

            return MealPlanPrintDocument.Day(
                id: day.dayID,
                weekdayText: day.formatted(weekdayFormat),
                weekdayShortText: day.formatted(weekdayShortFormat),
                weekdayIndex: weekdayIndex(of: day),
                dateText: day.formatted(dateFormat),
                dayNumberText: dayNumberText(for: day, isFirstOfRange: day == days.first, format: dateFormat),
                isToday: day.isSameDay(as: now),
                isWeekend: calendar.isDateInWeekend(day),
                meals: meals,
                energyText: facts.map {
                    NutritionFormatting.energy($0, unit: energyUnit, locale: locale)
                },
                macrosText: options.macros ? facts.map { macrosText($0, locale: locale) } : nil,
                standingSymbolName: standing?.symbolName,
                standingText: standing?.localizedName
            )
        }

        let summary: MealPlanPrintDocument.Summary? = options.summary && settings.content.includesPlan
            ? self.summary(
                days: days,
                nutrition: nutrition,
                options: options,
                unit: energyUnit,
                locale: locale
            )
            : nil

        return MealPlanPrintDocument(
            title: householdName.isEmpty ? "MealPlan" : householdName,
            subtitle: settings.content.includesPlan
                ? subtitle(for: range, locale: locale)
                : shoppingSubtitle(for: shoppingItems, locale: locale) ?? "",
            days: printedDays,
            summary: summary,
            shoppingList: settings.content.includesShoppingList
                ? shoppingList(shoppingItems, locale: locale)
                : nil,
            footnote: footnote(printedAt: now, showsNutrition: options.isAnythingOn),
            showsNutrition: options.isAnythingOn
        )
    }

    // MARK: - Pieces

    @MainActor
    private static func printEntry(
        _ entry: MealPlanEntry,
        options: PrintNutritionOptions,
        unit: EnergyUnit,
        nutrition: WeekNutritionSummary?,
        showsNotes: Bool,
        locale: Locale
    ) -> MealPlanPrintDocument.Entry {
        var energyText: String?
        var macrosText: String?
        if options.perMeal, let dish = entry.dish,
           let facts = trustworthyFacts(nutrition?.estimate(for: dish)) {
            energyText = NutritionFormatting.energy(facts, unit: unit, locale: locale)
            if options.macros {
                macrosText = self.macrosText(facts, locale: locale)
            }
        }

        let note = showsNotes ? entry.note?.trimmingCharacters(in: .whitespacesAndNewlines) : nil

        return MealPlanPrintDocument.Entry(
            id: entry.uuid.uuidString,
            title: entry.displayTitle,
            servingsText: entry.servingsOverride.map { String(localized: "for \($0)") },
            note: (note?.isEmpty ?? true) ? nil : note,
            energyText: energyText,
            macrosText: macrosText,
            isEatingOut: entry.isEatingOut
        )
    }

    /// The figures of an estimate worth printing, or `nil` when too much of it
    /// is missing for the total to mean anything.
    static func trustworthyFacts(_ estimate: NutritionEstimate?) -> NutritionFacts? {
        guard let estimate, estimate.isTrustworthy, estimate.facts.energyKcal > 0 else { return nil }
        return estimate.facts
    }

    /// The day number on its own, except where the month turns over — and on
    /// the first cell printed, so a grid that opens mid-month says which.
    static func dayNumberText(
        for day: Date,
        isFirstOfRange: Bool,
        format: Date.FormatStyle
    ) -> String {
        let calendar = Calendar.current
        let isFirstOfMonth = calendar.component(.day, from: day) == 1
        return isFirstOfMonth || isFirstOfRange
            ? day.formatted(format)
            : day.formatted(Date.FormatStyle.dateTime.day())
    }

    /// Monday 0 … Sunday 6, whatever the locale's first weekday is. The
    /// calendar block puts each day in the column for its weekday, and the
    /// plan's own week sections are Monday-based, so this is too.
    static func weekdayIndex(of day: Date) -> Int {
        let weekday = Date.mondayCalendar.component(.weekday, from: day)
        return (weekday + 5) % 7
    }

    /// "P 92 g · C 210 g · F 74 g" — initials, not words: this sits in a
    /// column narrow enough that "Protein" alone would wrap.
    static func macrosText(_ facts: NutritionFacts, locale: Locale = .current) -> String {
        let protein = NutritionFormatting.grams(facts.proteinGrams, locale: locale)
        let carbs = NutritionFormatting.grams(facts.carbGrams, locale: locale)
        let fat = NutritionFormatting.grams(facts.fatGrams, locale: locale)
        return String(localized: "P \(protein) · C \(carbs) · F \(fat)")
    }

    private static func summary(
        days: [Date],
        nutrition: WeekNutritionSummary?,
        options: PrintNutritionOptions,
        unit: EnergyUnit,
        locale: Locale
    ) -> MealPlanPrintDocument.Summary {
        let dayFormat = Date.FormatStyle.dateTime.weekday(.abbreviated).day().month(.abbreviated)
        var counted: [(day: Date, facts: NutritionFacts)] = []
        var combined = NutritionEstimate.unavailable

        for day in days {
            let estimate = nutrition?.estimate(on: day)
            if let estimate { combined.merge(estimate) }
            if let facts = trustworthyFacts(estimate) {
                counted.append((day, facts))
            }
        }

        // An average over the days that could be estimated — never over the
        // whole range, which would quietly count an unplanned Thursday as a
        // day of nothing and drag the figure down.
        let divisor = Double(max(1, counted.count))
        let average = counted
            .map(\.facts)
            .reduce(NutritionFacts.zero, +)
            .scaled(by: 1 / divisor)

        let lightest = counted.min { $0.facts.energyKcal < $1.facts.energyKcal }
        let heaviest = counted.max { $0.facts.energyKcal < $1.facts.energyKcal }

        return MealPlanPrintDocument.Summary(
            averageEnergyText: counted.isEmpty
                ? "—"
                : NutritionFormatting.energy(average, unit: unit, locale: locale),
            averageMacrosText: options.macros && !counted.isEmpty
                ? macrosText(average, locale: locale)
                : nil,
            countedDaysText: String(localized: "From \(counted.count) of \(days.count) days"),
            lightestDayText: counted.count > 1
                ? lightest.map { String(localized: "Lightest: \($0.day.formatted(dayFormat))") }
                : nil,
            heaviestDayText: counted.count > 1
                ? heaviest.map { String(localized: "Heaviest: \($0.day.formatted(dayFormat))") }
                : nil,
            coverageNote: NutritionFormatting.coverageNote(for: combined),
            missingNote: NutritionFormatting.missingList(for: combined)
        )
    }

    // MARK: - The shopping list

    /// The list exactly as the Shopping screen has it: same aisles, same
    /// order, ticked lines left out because they are already in the cupboard.
    @MainActor
    static func shoppingList(
        _ items: [ShoppingListItem],
        locale: Locale = .current
    ) -> MealPlanPrintDocument.ShoppingList {
        let outstanding = items.filter { !$0.isChecked }
        let ticked = items.count - outstanding.count

        let groups = ShoppingListGrouping.aisles(outstanding).map { aisle in
            MealPlanPrintDocument.ShoppingGroup(
                id: aisle.name,
                name: aisle.name,
                lines: aisle.items.map { item in
                    let amount = item.displayText?.trimmingCharacters(in: .whitespaces)
                    return MealPlanPrintDocument.ShoppingLine(
                        id: item.uuid.uuidString,
                        name: item.name,
                        amountText: (amount?.isEmpty ?? true) ? nil : amount
                    )
                }
            )
        }

        return MealPlanPrintDocument.ShoppingList(
            title: String(localized: "Shopping list"),
            subtitle: shoppingSubtitle(for: items, locale: locale),
            groups: groups,
            note: ticked > 0
                ? String(localized: "\(ticked) ticked items left out.")
                : nil
        )
    }

    /// The days the generated part of the list was built for. Hand-added lines
    /// carry no range and are ignored here — they are what someone typed in,
    /// not something the plan asked for.
    @MainActor
    private static func shoppingSubtitle(
        for items: [ShoppingListItem],
        locale: Locale
    ) -> String? {
        let starts = items.compactMap(\.rangeStart)
        let ends = items.compactMap(\.rangeEnd)
        guard let first = starts.min(), let last = ends.max(), last > first else { return nil }
        return subtitle(for: DayRange(start: first, end: last), locale: locale)
    }

    private static func subtitle(for range: DayRange, locale: Locale) -> String {
        let days = range.days
        guard let first = days.first, let last = days.last else { return "" }
        let format = Date.FormatStyle.dateTime.day().month(.abbreviated).year()
        let span = "\(first.formatted(format)) – \(last.formatted(format))"
        // A run of exactly one Monday-to-Sunday week gets its week number, the
        // way the planner's own section headers do.
        if days.count == 7, first == first.startOfWeek() {
            let week = Date.mondayCalendar.component(.weekOfYear, from: first)
            return String(localized: "Week \(week) · \(span)")
        }
        return span
    }

    private static func footnote(printedAt: Date, showsNutrition: Bool) -> String {
        let printed = String(
            localized: "Printed \(printedAt.formatted(date: .abbreviated, time: .shortened)) with MealPlan"
        )
        guard showsNutrition else { return printed }
        return printed + " · " + String(
            localized: "Nutrition figures are estimates per person, accurate to about ±20 %."
        )
    }
}
