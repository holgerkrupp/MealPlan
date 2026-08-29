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

    @Test func temperatureConversion() {
        #expect(abs(UnitConversion.celsiusToFahrenheit(180) - 356) < 0.001)
        #expect(abs(UnitConversion.fahrenheitToCelsius(356) - 180) < 0.001)
        #expect(UnitConversion.ovenTemperature(celsius: 180, system: .metric) == "180 °C")
        #expect(UnitConversion.ovenTemperature(celsius: 180, system: .imperial).contains("°F"))
    }

    @Test func volumeToWeightFlagsKnownDensity() {
        let known = UnitConversion.weight(fromVolume: 1000, ingredientName: "Mehl")
        #expect(known.known)
        #expect(known.grams < 1000) // flour is lighter than water

        let unknown = UnitConversion.weight(fromVolume: 1000, ingredientName: "Marshmallows")
        #expect(unknown.known == false)
    }
}
