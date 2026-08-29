import Testing
import Foundation
@testable import MealPlan

struct UnitConversionTests {

    @Test func metricMassScales() {
        let d = UnitConversion.string(for: .grams(1500), system: .metric, locale: Locale(identifier: "de_DE"))
        #expect(d.text.contains("kg"))
        #expect(d.isApproximate == false)
    }

    @Test func imperialMassIsApproximate() {
        let d = UnitConversion.string(for: .grams(500), system: .imperial, locale: Locale(identifier: "en_US"))
        #expect(d.text.contains("oz") || d.text.contains("lb"))
        #expect(d.isApproximate)
    }

    @Test func metricVolumeToLitres() {
        let d = UnitConversion.string(for: .millilitres(2000), system: .metric, locale: Locale(identifier: "de_DE"))
        #expect(d.text.contains("l"))
    }

    @Test func countUsesPreferredUnit() {
        let d = UnitConversion.string(for: .pieces(2), system: .metric, preferredUnit: "Bund")
        #expect(d.text.contains("Bund"))
    }

    @Test func eggsAlwaysRoundToWholeCounts() {
        let up = UnitConversion.string(
            for: .pieces(2.75), system: .metric,
            ingredientName: "Eier", locale: Locale(identifier: "en_US")
        )
        #expect(up.text == "3 ×")
        #expect(up.isApproximate)

        let down = UnitConversion.string(
            for: .pieces(2.25), system: .metric,
            ingredientName: "eggs", locale: Locale(identifier: "en_US")
        )
        #expect(down.text == "2 ×")
        #expect(down.isApproximate)

        let scaledWayDown = UnitConversion.string(
            for: .pieces(0.25), system: .metric,
            ingredientName: "Ei", locale: Locale(identifier: "en_US")
        )
        #expect(scaledWayDown.text == "1 ×")
    }

    @Test func otherSmallCountsRoundToUsefulHalves() {
        let lemon = UnitConversion.string(
            for: .pieces(2.25), system: .metric,
            ingredientName: "Lemons", locale: Locale(identifier: "en_US")
        )
        #expect(lemon.text == "2.5 ×")
        #expect(lemon.isApproximate)

        let large = UnitConversion.string(
            for: .pieces(12.4), system: .metric,
            ingredientName: "Tomatoes", locale: Locale(identifier: "en_US")
        )
        #expect(large.text == "12 ×")
    }

    @Test func eggplantIsNotMistakenForEggs() {
        let display = UnitConversion.string(
            for: .pieces(2.25), system: .metric,
            ingredientName: "Eggplant", locale: Locale(identifier: "en_US")
        )
        #expect(display.text == "2.5 ×")
    }

    @Test func exactWholeEggCountIsNotMarkedApproximate() {
        let display = UnitConversion.string(
            for: .pieces(3), system: .metric,
            ingredientName: "Eggs", locale: Locale(identifier: "en_US")
        )
        #expect(display.text == "3 ×")
        #expect(!display.isApproximate)
    }

    @Test func exactModePreservesFractionalCounts() {
        let display = UnitConversion.string(
            for: .pieces(2.75),
            system: .metric,
            ingredientName: "Eggs",
            roundsAmounts: false,
            locale: Locale(identifier: "en_US")
        )
        #expect(display.text == "2.75 ×")
        #expect(!display.isApproximate)
    }

    @Test func metricConversionsUsePracticalStepsByDefault() {
        // Canonical values produced by one imperial ounce and fluid ounce.
        let mass = UnitConversion.string(
            for: .grams(28.3495),
            system: .metric,
            locale: Locale(identifier: "en_US")
        )
        let volume = UnitConversion.string(
            for: .millilitres(29.5735),
            system: .metric,
            locale: Locale(identifier: "en_US")
        )

        #expect(mass.text == "28 g")
        #expect(mass.isApproximate)
        #expect(volume.text == "30 ml")
        #expect(volume.isApproximate)
    }

    @Test func exactModePreservesConvertedMetricValues() {
        let mass = UnitConversion.string(
            for: .grams(28.3495),
            system: .metric,
            roundsAmounts: false,
            locale: Locale(identifier: "en_US")
        )
        let volume = UnitConversion.string(
            for: .millilitres(29.5735),
            system: .metric,
            roundsAmounts: false,
            locale: Locale(identifier: "en_US")
        )

        #expect(mass.text == "28.3495 g")
        #expect(!mass.isApproximate)
        #expect(volume.text == "29.5735 ml")
        #expect(!volume.isApproximate)
    }

    @Test func imperialConversionsCanBeRoundedOrExact() {
        let rounded = UnitConversion.string(
            for: .grams(500),
            system: .imperial,
            locale: Locale(identifier: "en_US")
        )
        let exact = UnitConversion.string(
            for: .grams(500),
            system: .imperial,
            roundsAmounts: false,
            locale: Locale(identifier: "en_US")
        )

        #expect(rounded.text == "17.75 oz")
        #expect(rounded.isApproximate)
        #expect(exact.text == "17.637 oz")
        #expect(!exact.isApproximate)
    }

    @Test func temperatureConversion() {
        #expect(abs(UnitConversion.celsiusToFahrenheit(180) - 356) < 0.001)
        #expect(abs(UnitConversion.fahrenheitToCelsius(356) - 180) < 0.001)
        #expect(UnitConversion.ovenTemperature(celsius: 180, system: .metric) == "180 °C")
        #expect(UnitConversion.ovenTemperature(celsius: 180, system: .imperial).contains("°F"))
        #expect(UnitConversion.ovenTemperature(
            celsius: 181.25,
            system: .metric,
            roundsAmounts: false,
            locale: Locale(identifier: "en_US")
        ) == "181.25 °C")
    }

    @Test func volumeToWeightFlagsKnownDensity() {
        let known = UnitConversion.weight(fromVolume: 1000, ingredientName: "Mehl")
        #expect(known.known)
        #expect(known.grams < 1000) // flour is lighter than water

        let unknown = UnitConversion.weight(fromVolume: 1000, ingredientName: "Marshmallows")
        #expect(unknown.known == false)
    }
}
