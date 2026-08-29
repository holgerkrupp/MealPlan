import Testing
import Foundation
@testable import MealPlan

struct GermanUnitParserTests {

    @Test func gramsAndKilograms() {
        let a = GermanUnitParser.parse("200 g Mehl")
        #expect(a.name == "Mehl")
        #expect(a.quantity == Quantity(value: 200, dimension: .mass))
        #expect(a.displayUnit == "g")
        #expect(a.isApproximate == false)

        let b = GermanUnitParser.parse("1,5 kg Kartoffeln")
        #expect(b.name == "Kartoffeln")
        #expect(b.quantity == Quantity(value: 1500, dimension: .mass))
    }

    @Test func gluedNumberAndUnit() {
        let a = GermanUnitParser.parse("500g Zwiebeln")
        #expect(a.quantity == Quantity(value: 500, dimension: .mass))
        #expect(a.name == "Zwiebeln")
    }

    @Test func tablespoonAndTeaspoonAreApproximateVolume() {
        let el = GermanUnitParser.parse("2 EL Olivenöl")
        #expect(el.quantity == Quantity(value: 30, dimension: .volume))
        #expect(el.displayUnit == "EL")
        #expect(el.isApproximate)

        let tl = GermanUnitParser.parse("1 TL Backpulver")
        #expect(tl.quantity == Quantity(value: 5, dimension: .volume))
        #expect(tl.isApproximate)
    }

    @Test func priseWithoutNumberDefaultsToOne() {
        let p = GermanUnitParser.parse("Prise Salz")
        #expect(p.name == "Salz")
        #expect(p.displayUnit == "Prise")
        #expect(p.quantity?.dimension == .mass)
        #expect(p.isApproximate)
    }

    @Test func bundIsACount() {
        let b = GermanUnitParser.parse("1 Bund Petersilie")
        #expect(b.name == "Petersilie")
        #expect(b.quantity == Quantity(value: 1, dimension: .count))
        #expect(b.displayUnit == "Bund")
    }

    @Test func bareNumberBecomesCount() {
        let e = GermanUnitParser.parse("3 Eier")
        #expect(e.name == "Eier")
        #expect(e.quantity == Quantity(value: 3, dimension: .count))
    }

    @Test func rangeTakesLowerBoundAndNotes() {
        let r = GermanUnitParser.parse("2-3 Stück Tomaten")
        #expect(r.name == "Tomaten")
        #expect(r.quantity == Quantity(value: 2, dimension: .count))
        #expect(r.isApproximate)
        #expect(r.note?.contains("2") == true)
    }

    @Test func fractions() {
        #expect(GermanUnitParser.parse("1/2 TL Zimt").quantity == Quantity(value: 2.5, dimension: .volume))
        #expect(GermanUnitParser.parse("½ Zitrone").quantity == Quantity(value: 0.5, dimension: .count))
        let mixed = GermanUnitParser.parse("1 1/2 Tassen Milch")
        #expect(mixed.quantity?.dimension == .volume)
        #expect((mixed.quantity?.value ?? 0) > 350) // ~355 ml
    }

    @Test func nonQuantifiablePhrasesGoToNote() {
        let a = GermanUnitParser.parse("Salz nach Geschmack")
        #expect(a.name == "Salz")
        #expect(a.quantity == nil)
        #expect(a.note?.localizedCaseInsensitiveContains("geschmack") == true)

        let b = GermanUnitParser.parse("etwas Öl")
        #expect(b.name == "Öl")
        #expect(b.quantity == nil)
    }

    @Test func parentheticalHintGivesConcreteWeight() {
        let a = GermanUnitParser.parse("1 Dose (400 g) Kidneybohnen")
        #expect(a.name == "Kidneybohnen")
        #expect(a.quantity == Quantity(value: 400, dimension: .mass))
    }

    @Test func imperialUnits() {
        #expect(GermanUnitParser.parse("2 cups flour").quantity?.dimension == .volume)
        #expect(GermanUnitParser.parse("8 oz butter").quantity == Quantity(value: 8 * 28.3495, dimension: .mass))
    }
}
