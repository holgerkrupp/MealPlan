import Foundation
import Testing

struct BarcodeProductLookupTests {
    @Test func localBarcodeNormalizationAndOpenFoodFactsMapping() async {
        let lookup = BarcodeProductLookup { request in
            #expect(request.url?.absoluteString.contains("4006381333931") == true)
            return BarcodeProductLookupResponse(
                statusCode: 200,
                body: Data(#"{"status":1,"product":{"product_name":"Haferdrink","brands":"Test Brand"}}"#.utf8)
            )
        }
        let outcome = await lookup.lookup(barcode: "4006 3813 33931")
        #expect(outcome == .found(name: "Haferdrink", brand: "Test Brand", source: "Open Food Facts"))
    }

    @Test func duplicateRequestsAreCoalescedAndResultsCached() async {
        let counter = Counter()
        let lookup = BarcodeProductLookup(cacheLifetime: 60) { _ in
            await counter.increment()
            try? await Task.sleep(for: .milliseconds(20))
            return BarcodeProductLookupResponse(statusCode: 200, body: Data(#"{"status":0}"#.utf8))
        }
        async let first = lookup.lookup(barcode: "123")
        async let second = lookup.lookup(barcode: "123")
        _ = await (first, second)
        _ = await lookup.lookup(barcode: "123")
        #expect(await counter.value == 1)
    }

    @Test func malformedAndOfflineResponsesRemainManualFallbacks() async {
        let malformed = BarcodeProductLookup { _ in
            BarcodeProductLookupResponse(statusCode: 200, body: Data("not json".utf8))
        }
        #expect(await malformed.lookup(barcode: "1") == .failed)

        let offline = BarcodeProductLookup { _ in throw URLError(.notConnectedToInternet) }
        #expect(await offline.lookup(barcode: "2") == .offline)
    }

    private actor Counter {
        var value = 0
        func increment() { value += 1 }
    }
}
