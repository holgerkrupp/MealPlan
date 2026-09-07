import Foundation

/// A hand-built document for `#Preview` and for looking at a layout change
/// without a store. Not gated behind `#if DEBUG` — `#Preview` bodies compile
/// in Release too, and this is useless to them if it doesn't.
enum MealPlanPrintPreview {

    static var document: MealPlanPrintDocument {
        let names = [
            ["Porridge mit Beeren", "Rührei"],
            ["Linsensalat"],
            ["Ofengemüse mit Halloumi"],
            [],
            ["Pasta al limone"],
            ["Sonntagsbraten"],
            ["Reste-Frittata"],
        ]
        let weekdays = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]

        let days = (0..<7).map { index -> MealPlanPrintDocument.Day in
            MealPlanPrintDocument.Day(
                id: "preview-\(index)",
                weekdayText: weekdays[index],
                dateText: "\(7 + index) Sep",
                isToday: index == 2,
                isWeekend: index >= 5,
                meals: [
                    MealPlanPrintDocument.Meal(
                        id: "breakfast",
                        name: "Breakfast",
                        symbolName: "sunrise",
                        entries: index == 0 ? [entry("Porridge", energy: "≈ 380 kcal")] : []
                    ),
                    MealPlanPrintDocument.Meal(
                        id: "lunch",
                        name: "Lunch",
                        symbolName: "sun.max",
                        entries: index % 2 == 0 ? [entry("Linsensalat", energy: "≈ 520 kcal")] : []
                    ),
                    MealPlanPrintDocument.Meal(
                        id: "dinner",
                        name: "Dinner",
                        symbolName: "sunset",
                        entries: names[index].map { entry($0, energy: "≈ 640 kcal") }
                    ),
                ],
                energyText: index == 3 ? nil : "≈ 2 140 kcal",
                macrosText: index == 3 ? nil : "P 92 g · C 210 g · F 74 g",
                standingSymbolName: index == 5 ? "arrow.up" : nil,
                standingText: index == 5 ? "Heavier than this week" : nil
            )
        }

        return MealPlanPrintDocument(
            title: "Familie Krupp",
            subtitle: "Week 37 · 7 Sep 2026 – 13 Sep 2026",
            days: days,
            summary: MealPlanPrintDocument.Summary(
                averageEnergyText: "≈ 2 140 kcal",
                averageMacrosText: "P 92 g · C 210 g · F 74 g",
                countedDaysText: "From 6 of 7 days",
                lightestDayText: "Lightest: Tue 8 Sep",
                heaviestDayText: "Heaviest: Sat 12 Sep",
                coverageNote: "From 46 of 51 ingredients.",
                missingNote: "No values for Kürbiskernöl and 2 more."
            ),
            shoppingList: shoppingList,
            footnote: "Printed 6 Sep 2026 at 18:20 with MealPlan · Nutrition figures are estimates per person, accurate to about ±20 %.",
            showsNutrition: true
        )
    }

    /// Thirty days starting on a Wednesday, for looking at the calendar block
    /// — including the ragged first row a span that doesn't start on a Monday
    /// produces.
    static var monthDocument: MealPlanPrintDocument {
        let dinners = [
            "Pasta al limone", "Ofengemüse mit Halloumi", "Linsencurry", "Sonntagsbraten",
            "Reste-Frittata", "Kürbissuppe", "Schnitzel", "Gnocchi mit Salbei",
            "Chili sin Carne", "Lachs mit Brokkoli", "Pizza", "Bratkartoffeln",
            "Ratatouille", "Hühnerfrikassee",
        ]
        let lunches = ["Linsensalat", "Suppe", "Bowl", "Reste"]

        var document = self.document
        document.days = (0..<30).map { offset in
            // Starts on a Wednesday: weekday index 2.
            let weekdayIndex = (2 + offset) % 7
            return MealPlanPrintDocument.Day(
                id: "month-\(offset)",
                weekdayText: ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"][weekdayIndex],
                weekdayShortText: ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"][weekdayIndex],
                weekdayIndex: weekdayIndex,
                dateText: "\((offset + 9) % 30 + 1) Sep",
                dayNumberText: offset == 0 ? "9 Sep" : ((offset + 9) % 30 + 1 == 1 ? "1 Oct" : "\((offset + 9) % 30 + 1)"),
                isToday: offset == 0,
                isWeekend: weekdayIndex >= 5,
                meals: [
                    MealPlanPrintDocument.Meal(
                        id: "breakfast",
                        name: "Breakfast",
                        symbolName: "sunrise",
                        entries: offset % 4 == 0 ? [entry("Porridge", energy: nil)] : []
                    ),
                    MealPlanPrintDocument.Meal(
                        id: "lunch",
                        name: "Lunch",
                        symbolName: "sun.max",
                        entries: offset % 3 == 0 ? [entry(lunches[offset % lunches.count], energy: nil)] : []
                    ),
                    MealPlanPrintDocument.Meal(
                        id: "dinner",
                        name: "Dinner",
                        symbolName: "sunset",
                        entries: offset % 5 == 4 ? [] : [entry(dinners[offset % dinners.count], energy: nil)]
                    ),
                ],
                energyText: offset % 5 == 4 ? nil : "≈ 2 140 kcal",
                macrosText: nil,
                standingSymbolName: nil,
                standingText: nil
            )
        }
        document.subtitle = "9 Sep 2026 – 8 Oct 2026"
        document.shoppingList = nil
        return document
    }

    static var shoppingList: MealPlanPrintDocument.ShoppingList {
        let aisles: [(String, [(String, String?)])] = [
            ("Obst & Gemüse", [
                ("Zwiebeln", "4 ×"), ("Knoblauch", "1 Knolle"), ("Möhren", "500 g"),
                ("Kartoffeln", "2 kg"), ("Zucchini", "3 ×"), ("Tomaten", "750 g"),
                ("Zitronen", "2 ×"), ("Petersilie", "1 Bund"), ("Rucola", "125 g"),
                ("Äpfel", "1 kg"), ("Lauch", "2 Stangen"), ("Paprika", "3 ×"),
            ]),
            ("Kühlregal", [
                ("Halloumi", "250 g"), ("Parmesan", "150 g"), ("Sahne", "400 ml"),
                ("Eier", "10 ×"), ("Butter", "250 g"), ("Naturjoghurt", "500 g"),
            ]),
            ("Fleisch & Fisch", [("Rinderbraten", "1,4 kg"), ("Lachsfilet", "600 g")]),
            ("Vorrat", [
                ("Basmatireis", "500 g"), ("Spaghetti", "1 kg"), ("Linsen", "500 g"),
                ("Gehackte Tomaten", "3 Dosen"), ("Olivenöl", nil), ("Gemüsebrühe", nil),
                ("Mehl", "1 kg"), ("Backpulver", "1 Päckchen"),
            ]),
            ("Backwaren", [("Vollkornbrot", "1 ×"), ("Brötchen", "6 ×")]),
            ("Sonstiges", [("Küchenrolle", nil), ("Alufolie", nil)]),
        ]
        return MealPlanPrintDocument.ShoppingList(
            title: "Shopping list",
            subtitle: "Week 37 · 7 Sep 2026 – 13 Sep 2026",
            groups: aisles.map { name, lines in
                MealPlanPrintDocument.ShoppingGroup(
                    id: name,
                    name: name,
                    lines: lines.map {
                        MealPlanPrintDocument.ShoppingLine(
                            id: "\(name)-\($0.0)",
                            name: $0.0,
                            amountText: $0.1
                        )
                    }
                )
            },
            note: "6 ticked items left out."
        )
    }

    private static func entry(_ title: String, energy: String?) -> MealPlanPrintDocument.Entry {
        MealPlanPrintDocument.Entry(
            id: UUID().uuidString,
            title: title,
            servingsText: nil,
            note: nil,
            energyText: energy,
            macrosText: nil
        )
    }
}
