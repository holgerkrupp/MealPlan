import Testing
import Foundation
import Compression
@testable import MealPlan

struct PaprikaArchiveTests {

    /// Wrap raw bytes as a gzip stream (10-byte header + raw DEFLATE + 8-byte trailer).
    private func gzip(_ input: Data) -> Data {
        let src = [UInt8](input)
        let cap = src.count + 1024
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: cap)
        defer { dst.deallocate() }
        let n = src.withUnsafeBufferPointer {
            compression_encode_buffer(dst, cap, $0.baseAddress!, src.count, nil, COMPRESSION_ZLIB)
        }
        var out = Data([0x1f, 0x8b, 0x08, 0x00, 0, 0, 0, 0, 0x00, 0xff])
        out.append(dst, count: n)
        var isize = UInt32(input.count).littleEndian
        out.append(Data([0, 0, 0, 0]))                    // fake CRC32
        withUnsafeBytes(of: &isize) { out.append(contentsOf: $0) }
        return out
    }

    private let recipeJSON = """
    {"name":"Linsensuppe","ingredients":"250 g Linsen\\n2 Karotten\\n1 Zwiebel\\nSalz",
     "directions":"Alles kochen.","servings":"4","prep_time":"15 min","cook_time":"1 hr",
     "source_url":"https://example.com/linsen","categories":["Suppen"]}
    """

    @Test func parsesSingleGzippedRecipe() throws {
        let data = gzip(Data(recipeJSON.utf8))
        let recipes = try PaprikaArchive.recipes(from: data)
        #expect(recipes.count == 1)
        let r = recipes[0]
        #expect(r.name == "Linsensuppe")
        #expect(r.ingredientLines.count == 4)
        #expect(r.servings == 4)
        #expect(r.prepTimeMinutes == 15)
        #expect(r.cookTimeMinutes == 60)
        #expect(r.importedSourceApp == "Paprika")
        #expect(r.sourceURL?.absoluteString == "https://example.com/linsen")
    }

    @Test func parsesPlainJSON() throws {
        let recipes = try PaprikaArchive.recipes(from: Data(recipeJSON.utf8))
        #expect(recipes.first?.name == "Linsensuppe")
    }

    @Test func durationParsing() {
        #expect(PaprikaArchive.durationMinutes("15 min") == 15)
        #expect(PaprikaArchive.durationMinutes("1 hr 30 min") == 90)
        #expect(PaprikaArchive.durationMinutes("1:30") == 90)
        #expect(PaprikaArchive.durationMinutes("45") == 45)
        #expect(PaprikaArchive.durationMinutes("") == nil)
    }

    @Test func rawDeflateRoundTrips() {
        let original = Data("Hallo Welt, dies ist ein Test mit Wiederholung Wiederholung Wiederholung".utf8)
        let cap = original.count + 512
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: cap)
        defer { dst.deallocate() }
        let n = [UInt8](original).withUnsafeBufferPointer {
            compression_encode_buffer(dst, cap, $0.baseAddress!, original.count, nil, COMPRESSION_ZLIB)
        }
        let compressed = Data(bytes: dst, count: n)
        let restored = RawDeflate.inflate(compressed, expectedSize: original.count)
        #expect(restored == original)
    }
}
