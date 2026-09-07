import Foundation
import Testing
@testable import MealPlan

struct RecipeFeedSuggestionsTests {
    @Test func regionBeatsLanguage() {
        // An English-speaking household living in Germany should still be
        // offered German sites — that is the point of asking the region first.
        let suggestions = RecipeFeedSuggestions.suggestions(for: Locale(identifier: "en_DE"))

        #expect(suggestions.contains { $0.name == "Küchengötter" })
        #expect(!suggestions.contains { $0.name == "Budget Bytes" })
    }

    @Test func languageIsTheFallbackForAnUnlistedRegion() {
        let suggestions = RecipeFeedSuggestions.suggestions(for: Locale(identifier: "de_BR"))

        #expect(suggestions.contains { $0.name == "Küchengötter" })
    }

    @Test func unknownRegionAndLanguageFallBackToEnglish() {
        let suggestions = RecipeFeedSuggestions.suggestions(for: Locale(identifier: "ja_JP"))

        #expect(suggestions.contains { $0.name == "Smitten Kitchen" })
    }

    @Test func austriaAndSwitzerlandShareTheGermanList() {
        let austria = RecipeFeedSuggestions.suggestions(for: Locale(identifier: "de_AT"))
        let swiss = RecipeFeedSuggestions.suggestions(for: Locale(identifier: "de_CH"))
        let germany = RecipeFeedSuggestions.suggestions(for: Locale(identifier: "de_DE"))

        #expect(austria == germany)
        #expect(swiss == germany)
    }

    @Test func everyRegionOffersSomething() {
        for identifier in ["en_US", "en_GB", "de_DE", "fr_FR", "it_IT", "es_ES", "nl_NL"] {
            let suggestions = RecipeFeedSuggestions.suggestions(for: Locale(identifier: identifier))
            #expect(suggestions.count >= 3, "\(identifier) has too few suggestions")
        }
    }

    @Test func everySuggestionHasAUsableURL() {
        for identifier in ["en_US", "en_GB", "de_DE", "fr_FR", "it_IT", "es_ES", "nl_NL"] {
            for suggestion in RecipeFeedSuggestions.suggestions(for: Locale(identifier: identifier)) {
                #expect(suggestion.url?.scheme == "https", "\(suggestion.name) is not https")
                #expect(!suggestion.displayHost.hasPrefix("www."), "\(suggestion.name) keeps the www prefix")
                #expect(!suggestion.detail.isEmpty)
            }
        }
    }

    @Test func aListNeverRepeatsASite() {
        for identifier in ["en_US", "en_GB", "de_DE", "fr_FR", "it_IT", "es_ES", "nl_NL"] {
            let suggestions = RecipeFeedSuggestions.suggestions(for: Locale(identifier: identifier))
            let hosts = suggestions.map(\.displayHost)
            #expect(Set(hosts).count == hosts.count, "\(identifier) repeats a host")
        }
    }
}
