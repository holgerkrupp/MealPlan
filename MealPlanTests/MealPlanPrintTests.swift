import Testing
import Foundation
import SwiftData
@testable import MealPlan

/// Transient model objects only — no `ModelContext`, per the rest of the suite.
@MainActor
@Suite(.serialized)
struct MealPlanPrintTests {

    // MARK: - Fixtures

    private func mealTypes() -> [MealType] {
        [
            MealType(key: "breakfast", name: "Breakfast", symbolName: "sunrise", sortOrder: 0),
            MealType(key: "lunch", name: "Lunch", symbolName: "sun.max", sortOrder: 1),
            MealType(key: "dinner", name: "Dinner", symbolName: "sunset", sortOrder: 2),
        ]
    }

    /// A dish whose every ingredient is in the bundled table, so its estimate
    /// clears the 75 % coverage bar and actually reaches the page.
    private func knownDish(_ name: String, servings: Int = 2) -> Dish {
        let dish = Dish(name: name)
        dish.servings = servings
        let line = DishIngredient(canonicalValue: 200, dimension: .mass, sortIndex: 0)
        line.ingredient = Ingredient(name: "Mehl")
        line.dish = dish
        dish.ingredients = [line]
        return dish
    }

    private func entry(_ day: Date, _ mealKey: String, dish: Dish?, note: String? = nil) -> MealPlanEntry {
        let entry = MealPlanEntry(date: day, mealKey: mealKey, dish: dish)
        entry.note = note
        return entry
    }

    private var monday: Date {
        Date(timeIntervalSince1970: 1_757_203_200).startOfWeek() // 7 Sep 2026, a Monday
    }

    private func settings(
        span: PrintSpan = .shownWeek,
        nutrition: PrintNutritionOptions = .none,
        showsEmptyMeals: Bool = true,
        showsNotes: Bool = true
    ) -> MealPlanPrintSettings {
        var settings = MealPlanPrintSettings()
        settings.span = span
        settings.nutrition = nutrition
        settings.showsEmptyMeals = showsEmptyMeals
        settings.showsNotes = showsNotes
        return settings
    }

    private func document(
        _ settings: MealPlanPrintSettings,
        entries: [MealPlanEntry],
        shoppingItems: [ShoppingListItem] = [],
        showsNutritionEstimates: Bool = true,
        range: DayRange? = nil
    ) -> MealPlanPrintDocument {
        MealPlanPrintBuilder.document(
            range: range ?? DayRange(start: monday, end: monday.adding(weeks: 1)),
            settings: settings,
            householdName: "Familie Krupp",
            energyUnit: .kilocalories,
            showsNutritionEstimates: showsNutritionEstimates,
            mealTypes: mealTypes(),
            entries: entries,
            shoppingItems: shoppingItems,
            now: monday
        )
    }

    // MARK: - Paper and page geometry

    @Test func landscapeTurnsThePaperRound() {
        let portrait = PrintPageGeometry(paper: .a4, orientation: .portrait)
        let landscape = PrintPageGeometry(paper: .a4, orientation: .landscape)
        #expect(portrait.size == CGSize(width: 595, height: 842))
        #expect(landscape.size == CGSize(width: 842, height: 595))
    }

    @Test func everyPaperSizeLeavesRoomToPrintIn() {
        for paper in PaperSize.allCases {
            for orientation in PrintOrientation.allCases {
                let geometry = PrintPageGeometry(paper: paper, orientation: orientation)
                #expect(geometry.contentSize.width > 0)
                #expect(geometry.contentSize.height > 0)
                #expect(geometry.contentSize.width < geometry.size.width)
            }
        }
    }

    // MARK: - Time spans

    @Test func theShownWeekIsTheMondayToSundayAroundTheReference() {
        let range = PrintSpan.shownWeek.range(reference: monday.adding(days: 3))
        #expect(range.start == monday)
        #expect(range.days.count == 7)
    }

    @Test func nextWeekIsTheOneAfterTheWeekOnScreen() {
        let range = PrintSpan.nextWeek.range(reference: monday.adding(days: 3))
        #expect(range.start == monday.adding(weeks: 1))
        #expect(range.days.count == 7)
    }

    @Test func rollingSpansStartToday() {
        let today = monday.adding(days: 2)
        #expect(PrintSpan.next7Days.range(reference: monday, today: today).start == today)
        #expect(PrintSpan.next14Days.range(reference: monday, today: today).days.count == 14)
        #expect(PrintSpan.next30Days.range(reference: monday, today: today).days.count == 30)
    }

    @Test func aCustomSpanRunsFromItsStartForItsLength() {
        let range = PrintSpan.custom.range(
            reference: monday,
            customStart: monday.adding(days: 3),
            customDayCount: 10
        )
        #expect(range.start == monday.adding(days: 3))
        #expect(range.days.count == 10)
    }

    @Test func anAbsurdCustomLengthIsClamped() {
        let range = PrintSpan.custom.range(reference: monday, customStart: monday, customDayCount: 5_000)
        #expect(range.days.count == MealPlanPrintSettings.dayCountRange.upperBound)
        #expect(MealPlanPrintSettings.clampedDayCount(0) == 1)
    }

    // MARK: - Settings persistence

    @Test func settingsSurviveBeingSavedAndReloaded() throws {
        let defaults = try #require(UserDefaults(suiteName: "print-tests-\(UUID().uuidString)"))
        defer { defaults.removePersistentDomain(forName: defaults.dictionaryRepresentation().description) }

        var settings = MealPlanPrintSettings()
        settings.paper = .a5
        settings.orientation = .portrait
        settings.span = .next14Days
        settings.customDayCount = 12
        settings.nutrition = PrintNutritionOptions(perMeal: true, perDay: false, summary: true, macros: true)
        settings.showsEmptyMeals = false
        settings.fitsOnOnePage = false
        settings.content = .planAndShoppingList
        settings.save(to: defaults)

        let loaded = MealPlanPrintSettings.load(from: defaults)
        #expect(loaded == settings)
    }

    @Test func unprintedBeforeMeansSensibleDefaults() throws {
        let defaults = try #require(UserDefaults(suiteName: "print-tests-empty-\(UUID().uuidString)"))
        let loaded = MealPlanPrintSettings.load(from: defaults)
        #expect(loaded.paper == .a4)
        #expect(loaded.orientation == .landscape)
        #expect(loaded.span == .shownWeek)
        #expect(loaded.fitsOnOnePage)
        #expect(loaded.content == .plan)
    }

    @Test func aStoredBlobThatNoLongerDecodesFallsBackInsteadOfFailing() throws {
        let defaults = try #require(UserDefaults(suiteName: "print-tests-junk-\(UUID().uuidString)"))
        defaults.set(Data("not json".utf8), forKey: MealPlanPrintSettings.defaultsKey)
        #expect(MealPlanPrintSettings.load(from: defaults) == MealPlanPrintSettings())
    }

    // MARK: - Pagination

    @Test func aWeekFitsOnOneLandscapeSheet() {
        let geometry = PrintPageGeometry(paper: .a4, orientation: .landscape)
        let columns = PrintPagination.columnsPerPage(
            contentWidth: geometry.contentSize.width,
            textScale: geometry.textScale
        )
        #expect(columns == 7)
    }

    @Test func asmallSheetTakesFewerDaysRatherThanThinnerColumns() {
        let geometry = PrintPageGeometry(paper: .a5, orientation: .portrait)
        let columns = PrintPagination.columnsPerPage(
            contentWidth: geometry.contentSize.width,
            textScale: geometry.textScale
        )
        #expect(columns >= 1)
        #expect(columns < 7)
    }

    @Test func wholeWeeksAreNeverSplitAcrossSheets() {
        #expect(PrintPagination.chunks(dayCount: 14, columnsPerPage: 7) == [0..<7, 7..<14])
    }

    @Test func aLeftoverDayIsBalancedRatherThanPrintedAlone() {
        #expect(PrintPagination.chunks(dayCount: 8, columnsPerPage: 7) == [0..<4, 4..<8])
        #expect(PrintPagination.chunks(dayCount: 10, columnsPerPage: 7) == [0..<5, 5..<10])
    }

    @Test func aShortRangeIsOnePage() {
        #expect(PrintPagination.chunks(dayCount: 3, columnsPerPage: 7) == [0..<3])
        #expect(PrintPagination.chunks(dayCount: 0, columnsPerPage: 7).isEmpty)
    }

    @Test func theSummaryRidesOnTheLastSheetRatherThanTakingOne() {
        let doc = document(
            settings(nutrition: PrintNutritionOptions(perMeal: false, perDay: true, summary: true, macros: false)),
            entries: [entry(monday, "dinner", dish: knownDish("Pfannkuchen"))]
        )
        let pages = PrintPagination.pages(
            for: doc,
            geometry: PrintPageGeometry(paper: .a4, orientation: .landscape)
        )
        #expect(pages.count == 1)
        #expect(pages[0].includesSummary)
    }

    @Test func acrossSeveralSheetsOnlyTheLastCarriesTheSummary() {
        let range = DayRange(start: monday, end: monday.adding(days: 24))
        let doc = document(
            settings(
                span: .custom,
                nutrition: PrintNutritionOptions(perMeal: false, perDay: true, summary: true, macros: false)
            ),
            entries: [],
            range: range
        )
        let pages = PrintPagination.pages(
            for: doc,
            geometry: PrintPageGeometry(paper: .a5, orientation: .portrait)
        )
        #expect(pages.count > 1)
        #expect(pages.filter { $0.includesSummary }.count == 1)
        #expect(pages.last?.includesSummary == true)
    }

    @Test func withoutASummaryNoSheetCarriesOne() {
        let doc = document(settings(), entries: [])
        let pages = PrintPagination.pages(
            for: doc,
            geometry: PrintPageGeometry(paper: .a4, orientation: .landscape)
        )
        #expect(pages == [PrintPage(body: .days(0..<7), pageNumber: 1, pageCount: 1, includesSummary: false)])
    }

    // MARK: - Fitting on one page

    @Test func fittingPutsAWholeWeekOnOnePortraitSheet() {
        let geometry = PrintPageGeometry(paper: .a4, orientation: .portrait)
        let roomy = PrintPagination.columnsPerPage(
            contentWidth: geometry.contentSize.width,
            textScale: geometry.textScale,
            dayCount: 7,
            compact: false
        )
        let fitted = PrintPagination.columnsPerPage(
            contentWidth: geometry.contentSize.width,
            textScale: geometry.textScale,
            dayCount: 7,
            compact: true
        )
        #expect(roomy < 7)
        #expect(fitted == 7)
    }

    @Test func fittingNeverSqueezesAColumnBelowWhatCanBeRead() {
        // A5 portrait genuinely cannot hold a week: seven columns there are
        // 47 pt, and the dish name would come out under 5 pt.
        let geometry = PrintPageGeometry(paper: .a5, orientation: .portrait)
        let columns = PrintPagination.columnsPerPage(
            contentWidth: geometry.contentSize.width,
            textScale: geometry.textScale,
            dayCount: 7,
            compact: true
        )
        #expect(columns < 7)
        let available = geometry.contentSize.width
            - PrintPagination.labelColumnWidth * geometry.textScale
        #expect(available / CGFloat(columns) >= PrintPagination.minimumColumnWidth)
    }

    @Test func everyPaperFitsAWeekOrSaysWhyNot() {
        for paper in PaperSize.allCases {
            for orientation in PrintOrientation.allCases {
                let geometry = PrintPageGeometry(paper: paper, orientation: orientation)
                let columns = PrintPagination.columnsPerPage(
                    contentWidth: geometry.contentSize.width,
                    textScale: geometry.textScale,
                    dayCount: 7,
                    compact: true
                )
                let available = geometry.contentSize.width
                    - PrintPagination.labelColumnWidth * geometry.textScale
                #expect(columns >= 1)
                #expect(available / CGFloat(columns) >= PrintPagination.minimumColumnWidth)
            }
        }
    }

    @Test func aMonthStillTakesSeveralSheetsHoweverHardItIsSqueezed() {
        let geometry = PrintPageGeometry(paper: .a4, orientation: .landscape)
        let columns = PrintPagination.columnsPerPage(
            contentWidth: geometry.contentSize.width,
            textScale: geometry.textScale,
            dayCount: 30,
            compact: true
        )
        #expect(columns < 30)
        #expect(columns > PrintPagination.maximumColumnsPerPage)
        #expect(PrintPagination.chunks(dayCount: 30, columnsPerPage: columns).count > 1)
    }

    @Test func fittingChangesNothingForASpanThatAlreadyFitsComfortably() {
        let geometry = PrintPageGeometry(paper: .a4, orientation: .landscape)
        for compact in [true, false] {
            #expect(PrintPagination.columnsPerPage(
                contentWidth: geometry.contentSize.width,
                textScale: geometry.textScale,
                dayCount: 5,
                compact: compact
            ) == 5)
        }
    }

    // MARK: - What lands on the page

    @Test func everyDayOfTheRangeGetsAColumnEvenWhenNothingIsPlanned() {
        let doc = document(settings(), entries: [entry(monday, "dinner", dish: knownDish("Pfannkuchen"))])
        #expect(doc.days.count == 7)
        #expect(doc.days[0].meals.count == 3)
        #expect(doc.days[0].meals.map(\.name) == ["Breakfast", "Lunch", "Dinner"])
        #expect(doc.days[0].meals.last?.entries.map(\.title) == ["Pfannkuchen"])
        #expect(doc.days[1].meals.allSatisfy { $0.isEmpty })
    }

    @Test func emptyMealsCanBeLeftOut() {
        let doc = document(
            settings(showsEmptyMeals: false),
            entries: [entry(monday, "dinner", dish: knownDish("Pfannkuchen"))]
        )
        #expect(doc.days[0].meals.map(\.id) == ["dinner"])
        #expect(doc.days[1].meals.isEmpty)
    }

    @Test func anExtraOnlyShowsOnTheDayItWasPlannedFor() {
        let doc = document(
            settings(),
            entries: [entry(monday, MealType.extraKey, dish: knownDish("Geburtstagskuchen"))]
        )
        #expect(doc.days[0].meals.map(\.id) == ["breakfast", "lunch", "dinner", MealType.extraKey])
        #expect(doc.days[1].meals.map(\.id) == ["breakfast", "lunch", "dinner"])
    }

    @Test func aNightOutIsPrintedByItsPlaceName() {
        let out = MealPlanEntry(date: monday, mealKey: "dinner")
        out.isEatingOut = true
        out.placeName = "Trattoria Bella"
        let doc = document(settings(), entries: [out])
        let printed = try? #require(doc.days[0].meals.last?.entries.first)
        #expect(printed?.title == "Trattoria Bella")
        #expect(printed?.isEatingOut == true)
    }

    @Test func notesRideAlongOrDont() {
        let entries = [entry(monday, "dinner", dish: knownDish("Pfannkuchen"), note: "doppelte Menge")]
        #expect(document(settings(), entries: entries).days[0].meals.last?.entries.first?.note == "doppelte Menge")
        #expect(document(settings(showsNotes: false), entries: entries).days[0].meals.last?.entries.first?.note == nil)
    }

    @Test func skippedAndPastDaysAreNotSpecialCasedAway() {
        // The builder is handed whatever the fetch returned; a day outside the
        // range simply doesn't appear, rather than shifting the grid.
        let doc = document(
            settings(),
            entries: [entry(monday.adding(days: -3), "dinner", dish: knownDish("Suppe"))]
        )
        #expect(doc.days.allSatisfy { $0.meals.allSatisfy { $0.isEmpty } })
    }

    // MARK: - Nutrition on the page

    @Test func perDayFiguresAppearOnlyWhenAskedFor() {
        let entries = [entry(monday, "dinner", dish: knownDish("Pfannkuchen"))]
        #expect(document(settings(), entries: entries).days[0].energyText == nil)

        let withDay = document(
            settings(nutrition: PrintNutritionOptions(perMeal: false, perDay: true, summary: false, macros: false)),
            entries: entries
        )
        #expect(withDay.days[0].energyText != nil)
        #expect(withDay.days[0].macrosText == nil)
        #expect(withDay.showsNutrition)
    }

    @Test func macrosAreASeparateSwitch() {
        let doc = document(
            settings(nutrition: PrintNutritionOptions(perMeal: true, perDay: true, summary: false, macros: true)),
            entries: [entry(monday, "dinner", dish: knownDish("Pfannkuchen"))]
        )
        #expect(doc.days[0].macrosText != nil)
        #expect(doc.days[0].meals.last?.entries.first?.macrosText != nil)
    }

    @Test func theHouseholdSwitchBeatsEveryPrintOption() {
        let doc = document(
            settings(nutrition: PrintNutritionOptions(perMeal: true, perDay: true, summary: true, macros: true)),
            entries: [entry(monday, "dinner", dish: knownDish("Pfannkuchen"))],
            showsNutritionEstimates: false
        )
        #expect(doc.summary == nil)
        #expect(doc.days[0].energyText == nil)
        #expect(doc.days[0].meals.last?.entries.first?.energyText == nil)
        #expect(!doc.showsNutrition)
        #expect(!doc.footnote.contains("±"))
    }

    @Test func aDishNothingIsKnownAboutLeavesTheDayBlankRatherThanUnderstated() {
        let mystery = Dish(name: "Omas Auflauf")
        let line = DishIngredient(canonicalValue: 3, dimension: .count, sortIndex: 0)
        line.ingredient = Ingredient(name: "Wxyzquux")
        line.dish = mystery
        mystery.ingredients = [line]

        let doc = document(
            settings(nutrition: PrintNutritionOptions(perMeal: true, perDay: true, summary: false, macros: false)),
            entries: [entry(monday, "dinner", dish: mystery)]
        )
        #expect(doc.days[0].energyText == nil)
        #expect(doc.days[0].meals.last?.entries.first?.energyText == nil)
    }

    @Test func theSummaryAveragesOnlyTheDaysItCouldEstimate() throws {
        let entries = (0..<3).map { entry(monday.adding(days: $0), "dinner", dish: knownDish("Pfannkuchen")) }
        let doc = document(
            settings(nutrition: PrintNutritionOptions(perMeal: false, perDay: true, summary: true, macros: false)),
            entries: entries
        )
        let summary = try #require(doc.summary)
        #expect(summary.countedDaysText.contains("3"))
        // Three identical days average to what one of them came to — not to
        // 3/7 of it, which is what averaging over the whole range would give.
        #expect(summary.averageEnergyText == doc.days[0].energyText)
        #expect(summary.averageMacrosText == nil)
        #expect(summary.lightestDayText != nil)
    }

    @Test func theSummaryCarriesMacrosOnlyWhenTheyAreAskedFor() throws {
        let entries = [entry(monday, "dinner", dish: knownDish("Pfannkuchen"))]
        let doc = document(
            settings(nutrition: PrintNutritionOptions(perMeal: false, perDay: true, summary: true, macros: true)),
            entries: entries
        )
        #expect(try #require(doc.summary).averageMacrosText != nil)
        // A single estimated day has no lighter or heavier day to be compared
        // with, and saying it is both would be nonsense.
        #expect(try #require(doc.summary).lightestDayText == nil)
    }

    @Test func aRangeWithNothingPlannedStillPrints() throws {
        let doc = document(
            settings(nutrition: PrintNutritionOptions(perMeal: true, perDay: true, summary: true, macros: true)),
            entries: []
        )
        let summary = try #require(doc.summary)
        #expect(summary.averageEnergyText == "—")
        #expect(summary.averageMacrosText == nil)
        #expect(doc.days.count == 7)
    }

    // MARK: - The shopping list

    private func shoppingItem(
        _ name: String,
        _ category: IngredientCategory,
        amount: String? = nil,
        checked: Bool = false,
        sortIndex: Int = 0,
        aisle: String? = nil
    ) -> ShoppingListItem {
        let item = ShoppingListItem(name: name, category: category)
        item.displayText = amount
        item.isChecked = checked
        item.sortIndex = sortIndex
        item.customAisleName = aisle
        item.rangeStart = monday
        item.rangeEnd = monday.adding(weeks: 1)
        return item
    }

    private var basket: [ShoppingListItem] {
        [
            shoppingItem("Zwiebeln", .produce, amount: "4 ×", sortIndex: 0),
            shoppingItem("Möhren", .produce, amount: "500 g", sortIndex: 1),
            shoppingItem("Butter", .dairy, amount: "250 g", sortIndex: 2),
            shoppingItem("Mehl", .pantry, checked: true, sortIndex: 3),
            shoppingItem("Salz", .spices, sortIndex: 4),
        ]
    }

    @Test func theListPrintsTheAislesInTheOrderTheShopIsWalked() throws {
        let list = MealPlanPrintBuilder.shoppingList(basket)
        #expect(list.groups.map(\.name) == ShoppingListGrouping.aisles(
            basket.filter { !$0.isChecked }
        ).map(\.name))
        #expect(list.groups.first?.lines.map(\.name) == ["Zwiebeln", "Möhren"])
        #expect(list.groups.first?.lines.first?.amountText == "4 ×")
    }

    @Test func tickedItemsAreLeftOutAndCounted() throws {
        let list = MealPlanPrintBuilder.shoppingList(basket)
        let names = list.groups.flatMap { $0.lines.map(\.name) }
        #expect(!names.contains("Mehl"))
        #expect(names.count == 4)
        #expect(try #require(list.note).contains("1"))
    }

    @Test func aListWithNothingTickedCarriesNoNote() {
        let items = basket.filter { !$0.isChecked }
        #expect(MealPlanPrintBuilder.shoppingList(items).note == nil)
    }

    @Test func anItemWithNoAmountPrintsWithoutOne() throws {
        let list = MealPlanPrintBuilder.shoppingList(basket)
        let salz = try #require(list.groups.flatMap(\.lines).first { $0.name == "Salz" })
        #expect(salz.amountText == nil)
    }

    @Test func aCustomAisleNameIsUsedOnPaperToo() throws {
        let items = [shoppingItem("Tofu", .other, amount: "400 g", aisle: "Asia-Regal")]
        let list = MealPlanPrintBuilder.shoppingList(items)
        #expect(list.groups.map(\.name) == ["Asia-Regal"])
    }

    // MARK: - What a printout is of

    @Test func printingOnlyTheListLeavesTheDaysOut() throws {
        var options = settings()
        options.content = .shoppingList
        options.nutrition = PrintNutritionOptions(perMeal: true, perDay: true, summary: true, macros: true)
        let doc = document(
            options,
            entries: [entry(monday, "dinner", dish: knownDish("Pfannkuchen"))],
            shoppingItems: basket
        )
        #expect(doc.days.isEmpty)
        #expect(doc.summary == nil)
        #expect(doc.shoppingList != nil)
        // The heading still says which days the list was built for.
        #expect(doc.subtitle.contains("Week"))
    }

    @Test func printingOnlyThePlanLeavesTheListOut() {
        var options = settings()
        options.content = .plan
        let doc = document(options, entries: [], shoppingItems: basket)
        #expect(doc.shoppingList == nil)
        #expect(doc.days.count == 7)
    }

    @Test func theListFollowsThePlanAndNeverCarriesTheSummary() throws {
        var options = settings(
            nutrition: PrintNutritionOptions(perMeal: false, perDay: true, summary: true, macros: false)
        )
        options.content = .planAndShoppingList
        let doc = document(
            options,
            entries: [entry(monday, "dinner", dish: knownDish("Pfannkuchen"))],
            shoppingItems: basket
        )
        let pages = PrintPagination.pages(
            for: doc,
            geometry: PrintPageGeometry(paper: .a4, orientation: .landscape)
        )
        #expect(pages.count == 2)
        #expect(pages[0].days != nil)
        #expect(pages[0].includesSummary)
        guard case .shopping = pages[1].body else {
            Issue.record("the shopping list should be the last sheet")
            return
        }
        #expect(!pages[1].includesSummary)
        #expect(pages.allSatisfy { $0.pageCount == 2 })
    }

    @Test func anEmptyListAddsNoSheet() {
        var options = settings()
        options.content = .planAndShoppingList
        let doc = document(options, entries: [], shoppingItems: [])
        let pages = PrintPagination.pages(
            for: doc,
            geometry: PrintPageGeometry(paper: .a4, orientation: .landscape)
        )
        #expect(pages.count == 1)
        #expect(pages[0].days != nil)
    }

    // MARK: - Pouring the list into columns

    private func groups(_ counts: [Int]) -> [MealPlanPrintDocument.ShoppingGroup] {
        counts.enumerated().map { index, count in
            MealPlanPrintDocument.ShoppingGroup(
                id: "aisle-\(index)",
                name: "Aisle \(index)",
                lines: (0..<count).map {
                    MealPlanPrintDocument.ShoppingLine(id: "\(index)-\($0)", name: "Item \($0)", amountText: nil)
                }
            )
        }
    }

    private func lineCount(_ sheets: [[[MealPlanPrintDocument.ShoppingGroup]]]) -> Int {
        sheets.flatMap { $0 }.flatMap { $0 }.reduce(0) { $0 + $1.lines.count }
    }

    @Test func aShortListStaysInOneColumn() {
        // Six items across three columns would be a ragged edge, not columns.
        let sheets = ShoppingListLayout.flow(
            groups: groups([3, 3]),
            columns: 3,
            columnHeight: 700
        )
        #expect(sheets.count == 1)
        #expect(sheets[0].count == 1)
    }

    @Test func aFullListIsBalancedAcrossTheColumnsRatherThanFillingTheFirst() {
        let geometry = PrintPageGeometry(paper: .a4, orientation: .portrait)
        let sheets = ShoppingListLayout.flow(
            groups: groups([12, 6, 2, 8, 2, 2]),
            columns: ShoppingListLayout.columns(contentWidth: geometry.contentSize.width),
            columnHeight: geometry.bodyHeight
        )
        #expect(sheets.count == 1)
        #expect(sheets[0].count == 3)
        // Balanced, not first-column-takes-all: no column holds most of it.
        let perColumn = sheets[0].map { column in column.reduce(0) { $0 + $1.lines.count } }
        #expect(perColumn.allSatisfy { $0 >= 8 })
        #expect(lineCount(sheets) == 32)
    }

    @Test func anAisleTooLongForAColumnContinuesInTheNextOneUnderItsOwnName() {
        let sheets = ShoppingListLayout.flow(
            groups: groups([40]),
            columns: 2,
            columnHeight: ShoppingListLayout.height(lineCount: 12)
        )
        let slices = sheets.flatMap { $0 }.flatMap { $0 }
        #expect(slices.count > 1)
        #expect(slices.allSatisfy { $0.name == "Aisle 0" })
        #expect(lineCount(sheets) == 40)
    }

    @Test func nothingIsEverDroppedOrDuplicatedHoweverItIsPoured() {
        for columns in 1...4 {
            for height in [80.0, 160.0, 400.0, 736.0] {
                let sheets = ShoppingListLayout.flow(
                    groups: groups([12, 6, 2, 8, 2, 2]),
                    columns: columns,
                    columnHeight: height
                )
                #expect(lineCount(sheets) == 32)
                #expect(sheets.allSatisfy { $0.count <= columns })
            }
        }
    }

    @Test func noColumnIsTallerThanTheSheetItIsOn() {
        let geometry = PrintPageGeometry(paper: .a5, orientation: .portrait)
        let sheets = ShoppingListLayout.flow(
            groups: groups(Array(repeating: 9, count: 12)),
            columns: ShoppingListLayout.columns(
                contentWidth: geometry.contentSize.width,
                textScale: geometry.textScale
            ),
            columnHeight: geometry.bodyHeight,
            textScale: geometry.textScale
        )
        #expect(sheets.count > 1)
        for sheet in sheets {
            for column in sheet {
                let height = column.enumerated().reduce(CGFloat.zero) { running, pair in
                    running
                        + (pair.offset == 0 ? 0 : ShoppingListLayout.aisleSpacing * geometry.textScale)
                        + ShoppingListLayout.height(
                            lineCount: pair.element.lines.count,
                            textScale: geometry.textScale
                        )
                }
                #expect(height <= geometry.bodyHeight)
            }
        }
    }

    // MARK: - Titles and filenames

    @Test func aFullWeekIsTitledByItsWeekNumber() {
        let doc = document(settings(), entries: [])
        #expect(doc.subtitle.contains("Week"))
        #expect(doc.title == "Familie Krupp")
    }

    @Test func anOddRangeIsTitledByItsDates() {
        let doc = document(
            settings(),
            entries: [],
            range: DayRange(start: monday.adding(days: 2), end: monday.adding(days: 6))
        )
        #expect(!doc.subtitle.contains("Week"))
        #expect(doc.days.count == 4)
    }

    @Test func theFilenameSaysWhoAndWhen() {
        let name = MealPlanPDFRenderer.filename(
            for: DayRange(start: monday, end: monday.adding(weeks: 1)),
            householdName: "Familie Krupp"
        )
        #expect(name.hasPrefix("Familie-Krupp-"))
        #expect(name.contains(monday.dayID))
        #expect(name.contains(monday.adding(days: 6).dayID))
        #expect(!name.contains(" "))
    }

    @Test func anUnnamedHouseholdStillGetsAFilename() {
        let name = MealPlanPDFRenderer.filename(
            for: DayRange(start: monday, end: monday.adding(days: 1)),
            householdName: "   "
        )
        #expect(name.hasPrefix("MealPlan-"))
    }
}
