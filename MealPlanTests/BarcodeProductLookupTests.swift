import Foundation
import Testing
@testable import MealPlan

struct BarcodeProductLookupTests {
    @Test func localBarcodeNormalizationAndOpenFoodFactsMapping() async {
        let lookup = BarcodeProductLookup { request in
            #expect(request.url?.path == "/api/v3.6/product/4006381333931.json")
            #expect(request.url?.query?.contains("fields=code") == true)
            #expect(request.httpBody == nil)
            #expect(request.value(forHTTPHeaderField: "User-Agent")?.isEmpty == false)
            return BarcodeProductLookupResponse(
                statusCode: 200,
                body: Data(#"{"status":"success","product":{"product_name":"Haferdrink","brands":"Test Brand"}}"#.utf8)
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

    @Test func cacheRemainsBounded() async {
        let counter = Counter()
        let lookup = BarcodeProductLookup(cacheLimit: 1) { _ in
            await counter.increment()
            return BarcodeProductLookupResponse(
                statusCode: 200,
                body: Data(#"{"status":1,"product":{"product_name":"Item"}}"#.utf8)
            )
        }
        let now = Date(timeIntervalSinceReferenceDate: 10)
        _ = await lookup.lookup(barcode: "1", now: now)
        _ = await lookup.lookup(barcode: "2", now: now)
        _ = await lookup.lookup(barcode: "1", now: now)
        #expect(await counter.value == 3)
    }

    @Test func cancellationCancelsTheUnderlyingRequestAndDoesNotCache() async {
        let gate = Gate()
        let counter = Counter()
        let lookup = BarcodeProductLookup { _ in
            await counter.increment()
            await gate.markStarted()
            do {
                try await Task.sleep(for: .seconds(30))
                return BarcodeProductLookupResponse(statusCode: 200, body: Data())
            } catch {
                throw error
            }
        }
        let pending = Task { await lookup.lookup(barcode: "999") }
        await gate.waitUntilStarted()
        await lookup.cancel(barcode: "999")
        #expect(await pending.value == .cancelled)
        _ = await lookup.lookup(barcode: "999")
        #expect(await counter.value == 2)
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

    private actor Gate {
        var started = false

        func markStarted() { started = true }

        func waitUntilStarted() async {
            while !started {
                try? await Task.sleep(for: .milliseconds(1))
            }
        }
    }
}
