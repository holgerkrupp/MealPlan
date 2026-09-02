import Testing
import Foundation
@testable import MealPlan

/// A `Dish` whose `collectionNames` column held a zero-length blob crashed the
/// app outright: the stock `NSSecureUnarchiveFromData` transformer raises an
/// Objective-C exception on undecodable bytes, which Swift cannot catch, so
/// every read of the property took the process down — most visibly when
/// widening the Mac window past 700pt brought `DishSidebarView` on screen.
struct LenientSecureUnarchiveTransformerTests {

    private let transformer = LenientSecureUnarchiveTransformer()

    @Test func emptyDataDecodesToAnEmptyArrayRatherThanThrowing() throws {
        let decoded = transformer.transformedValue(Data())
        // Not nil: the array attributes are non-optional, so Core Data rejects
        // a nil with validation error 1570 and CloudKit stops mirroring.
        let array = try #require(decoded as? [String])
        #expect(array.isEmpty)
    }

    @Test func realArchivesStillRoundTrip() throws {
        let names = ["Weeknight", "Christmas"]
        let data = try #require(transformer.reverseTransformedValue(names) as? Data)
        #expect(transformer.transformedValue(data) as? [String] == names)
    }

    @Test func undecodableBytesDecodeToNilInsteadOfRaising() {
        #expect(transformer.transformedValue(Data([0xDE, 0xAD, 0xBE, 0xEF])) == nil)
    }

    @Test func registrationReplacesTheSharedTransformer() {
        LenientSecureUnarchiveTransformer.register()
        let installed = ValueTransformer(forName: LenientSecureUnarchiveTransformer.name)
        #expect(installed is LenientSecureUnarchiveTransformer)
    }
}
