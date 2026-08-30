import Foundation
import Compression

/// Reads Paprika recipe exports: `.paprikarecipes` (a ZIP of gzipped JSON
/// files) and single `.paprikarecipe` files (one gzipped JSON). No external
/// dependencies — ZIP + gzip are decoded with `libcompression`.
enum PaprikaArchive {

    struct PaprikaRecipe: Decodable {
        var name: String?
        var ingredients: String?
        var directions: String?
        var notes: String?
        var servings: String?
        var prep_time: String?
        var cook_time: String?
        var source_url: String?
        var source: String?
        var photo_data: String?     // base64 JPEG
        var categories: [String]?
    }

    /// Parse an export into importable recipes.
    static func recipes(from data: Data) throws -> [ImportedRecipe] {
        let jsonBlobs: [Data]
        if data.starts(with: [0x50, 0x4B, 0x03, 0x04]) {           // "PK\x03\x04"
            jsonBlobs = try Zip.entries(in: data).compactMap { entry in
                try? Gzip.decompressIfNeeded(entry.data)
            }
        } else if data.starts(with: [0x1F, 0x8B]) {                 // gzip magic
            jsonBlobs = [try Gzip.decompress(data)]
        } else {
            jsonBlobs = [data]
        }

        let decoder = JSONDecoder()
        var results: [ImportedRecipe] = []
        for blob in jsonBlobs {
            // A blob may be one recipe object or an array of them.
            if let one = try? decoder.decode(PaprikaRecipe.self, from: blob) {
                results.append(map(one))
            } else if let many = try? decoder.decode([PaprikaRecipe].self, from: blob) {
                results.append(contentsOf: many.map(map))
            }
        }
        guard !results.isEmpty else { throw RecipeImportError.unreadableFile }
        return results
    }

    // MARK: - Mapping

    static func map(_ p: PaprikaRecipe) -> ImportedRecipe {
        var recipe = ImportedRecipe(
            name: (p.name ?? String(localized: "Imported recipe")).trimmedCollapsed,
            sourceURL: p.source_url.flatMap(URL.init(string:))
        )
        recipe.importedSourceApp = "Paprika"
        recipe.needsReview = false
        recipe.ingredientLines = ingredientLines(from: p.ingredients)
        recipe.instructions = [p.directions, p.notes].compactMap { $0?.nilIfEmpty }.joined(separator: "\n\n").nilIfEmpty
        recipe.servings = p.servings?.firstInteger
        recipe.prepTimeMinutes = durationMinutes(p.prep_time)
        recipe.cookTimeMinutes = durationMinutes(p.cook_time)
        recipe.categories = p.categories ?? []
        // Paprika's categories are the closest thing it has to tags.
        recipe.tagNames = recipe.categories
        if let b64 = p.photo_data, let raw = Data(base64Encoded: b64, options: .ignoreUnknownCharacters) {
            recipe.imageData = ImagePreparation.prepared(from: raw)
        }
        if recipe.ingredientLines.isEmpty && recipe.instructions == nil { recipe.needsReview = true }
        return recipe
    }

    /// Paprika normally exports one ingredient per line. Some import sources
    /// (including Chefkoch) instead export an amount and its name as two
    /// consecutive lines. Join only an amount-only line with what follows so
    /// ordinary lines such as "2 Karotten" remain untouched.
    static func ingredientLines(from raw: String?) -> [String] {
        let lines = (raw ?? "")
            .replacingOccurrences(of: "<br />", with: "\n", options: .caseInsensitive)
            .replacingOccurrences(of: "<br/>", with: "\n", options: .caseInsensitive)
            .replacingOccurrences(of: "<br>", with: "\n", options: .caseInsensitive)
            .components(separatedBy: .newlines)
            .map { $0.trimmedCollapsed }
            .filter { !$0.isEmpty }

        var result: [String] = []
        var pendingAmount: String?
        for line in lines {
            if isAmountOnlyLine(line) {
                // An unpaired amount is still meaningful, so retain it rather
                // than silently dropping it if a malformed export has two in
                // a row.
                if let pendingAmount { result.append(pendingAmount) }
                pendingAmount = line
            } else if let amount = pendingAmount {
                result.append("\(amount) \(line)")
                pendingAmount = nil
            } else if isQualifier(line), !result.isEmpty {
                // Paprika puts recipe-site notes such as "TK", "oder Mehl"
                // and "je nach Größe" on their own lines. Keep the note with
                // the ingredient it describes.
                result[result.count - 1] += " (\(line))"
            } else {
                result.append(line)
            }
        }
        if let pendingAmount { result.append(pendingAmount) }
        return result
    }

    private static func isAmountOnlyLine(_ line: String) -> Bool {
        let parsed = GermanUnitParser.parse(line)
        if parsed.quantity != nil, parsed.name == line { return true }

        // "1 Rolle(n)" is a common Paprika/Chefkoch quantity line. Rolle is
        // not a canonical unit in the grocery parser, hence the explicit case.
        return line.range(
            of: #"^\s*[0-9]+(?:[.,][0-9]+)?\s+rolle(?:\(n\))?\s*$"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    private static func isQualifier(_ line: String) -> Bool {
        let lowered = line.lowercased()
        return ["tk", "evtl", "evtl.", "optional", "n. b.", "n.b."].contains(lowered)
            || lowered.hasPrefix("oder ")
            || lowered.hasPrefix("je nach ")
            || lowered.hasPrefix("evtl")
            || lowered.hasPrefix("optional")
    }

    /// "15 min", "1 hr 30 min", "1:30", "45" → minutes.
    static func durationMinutes(_ raw: String?) -> Int? {
        guard let raw = raw?.lowercased(), !raw.isEmpty else { return nil }
        if raw.contains(":") {
            let parts = raw.split(separator: ":").compactMap { Int($0) }
            if parts.count == 2 { return parts[0] * 60 + parts[1] }
        }
        var total = 0
        var matched = false
        let scanner = Scanner(string: raw)
        while !scanner.isAtEnd {
            if let value = scanner.scanInt() {
                let unit = scanner.scanCharacters(from: .letters)?.trimmingCharacters(in: .whitespaces) ?? ""
                if unit.hasPrefix("h") || unit.hasPrefix("std") { total += value * 60; matched = true }
                else if unit.hasPrefix("m") || unit.hasPrefix("min") { total += value; matched = true }
                else if unit.isEmpty { total += value; matched = true }
            } else {
                _ = scanner.scanCharacters(from: CharacterSet.decimalDigits.inverted)
            }
        }
        return matched && total > 0 ? total : nil
    }
}

// MARK: - Minimal ZIP reader (central-directory based, store + deflate)

enum Zip {
    struct Entry { var name: String; var data: Data }

    static func entries(in archive: Data) throws -> [Entry] {
        let bytes = [UInt8](archive)
        guard let eocd = findEOCD(bytes) else { throw RecipeImportError.unreadableFile }
        let count = readU16(bytes, eocd + 10)
        var cdOffset = Int(readU32(bytes, eocd + 16))
        var entries: [Entry] = []

        for _ in 0..<count {
            guard cdOffset + 46 <= bytes.count, readU32(bytes, cdOffset) == 0x02014b50 else { break }
            let method = readU16(bytes, cdOffset + 10)
            let compSize = Int(readU32(bytes, cdOffset + 20))
            let uncompSize = Int(readU32(bytes, cdOffset + 24))
            let nameLen = readU16(bytes, cdOffset + 28)
            let extraLen = readU16(bytes, cdOffset + 30)
            let commentLen = readU16(bytes, cdOffset + 32)
            let localOffset = Int(readU32(bytes, cdOffset + 42))
            let name = String(bytes: bytes[(cdOffset + 46)..<(cdOffset + 46 + nameLen)], encoding: .utf8) ?? "recipe"

            // Local file header: 30 bytes + name + extra
            if localOffset + 30 <= bytes.count, readU32(bytes, localOffset) == 0x04034b50 {
                let lNameLen = readU16(bytes, localOffset + 26)
                let lExtraLen = readU16(bytes, localOffset + 28)
                let dataStart = localOffset + 30 + lNameLen + lExtraLen
                if dataStart + compSize <= bytes.count {
                    let comp = Data(bytes[dataStart..<(dataStart + compSize)])
                    let payload: Data
                    switch method {
                    case 0: payload = comp
                    case 8: payload = RawDeflate.inflate(comp, expectedSize: max(uncompSize, comp.count * 4)) ?? Data()
                    default: payload = Data()
                    }
                    if !payload.isEmpty, !name.hasSuffix("/") {
                        entries.append(Entry(name: name, data: payload))
                    }
                }
            }
            cdOffset += 46 + nameLen + extraLen + commentLen
        }
        guard !entries.isEmpty else { throw RecipeImportError.unreadableFile }
        return entries
    }

    private static func findEOCD(_ bytes: [UInt8]) -> Int? {
        guard bytes.count >= 22 else { return nil }
        var i = bytes.count - 22
        let lower = max(0, bytes.count - 22 - 65536)
        while i >= lower {
            if readU32(bytes, i) == 0x06054b50 { return i }
            i -= 1
        }
        return nil
    }

    private static func readU16(_ b: [UInt8], _ o: Int) -> Int {
        guard o + 1 < b.count else { return 0 }
        return Int(b[o]) | (Int(b[o + 1]) << 8)
    }
    private static func readU32(_ b: [UInt8], _ o: Int) -> UInt32 {
        guard o + 3 < b.count else { return 0 }
        return UInt32(b[o]) | (UInt32(b[o + 1]) << 8) | (UInt32(b[o + 2]) << 16) | (UInt32(b[o + 3]) << 24)
    }
}

// MARK: - gzip / raw deflate via libcompression

enum Gzip {
    static func decompressIfNeeded(_ data: Data) throws -> Data {
        if data.starts(with: [0x1F, 0x8B]) { return try decompress(data) }
        return data
    }

    static func decompress(_ data: Data) throws -> Data {
        let bytes = [UInt8](data)
        guard bytes.count > 18, bytes[0] == 0x1F, bytes[1] == 0x8B, bytes[2] == 0x08 else {
            throw RecipeImportError.unreadableFile
        }
        let flags = bytes[3]
        var index = 10
        if flags & 0x04 != 0 {                       // FEXTRA
            let xlen = Int(bytes[index]) | (Int(bytes[index + 1]) << 8)
            index += 2 + xlen
        }
        if flags & 0x08 != 0 { while index < bytes.count, bytes[index] != 0 { index += 1 }; index += 1 } // FNAME
        if flags & 0x10 != 0 { while index < bytes.count, bytes[index] != 0 { index += 1 }; index += 1 } // FCOMMENT
        if flags & 0x02 != 0 { index += 2 }          // FHCRC

        let isize = bytes.count >= 4
            ? Int(bytes[bytes.count - 4]) | (Int(bytes[bytes.count - 3]) << 8)
                | (Int(bytes[bytes.count - 2]) << 16) | (Int(bytes[bytes.count - 1]) << 24)
            : 0
        let deflate = Data(bytes[index..<(bytes.count - 8)])
        guard let out = RawDeflate.inflate(deflate, expectedSize: max(isize, deflate.count * 5)) else {
            throw RecipeImportError.unreadableFile
        }
        return out
    }
}

enum RawDeflate {
    /// Inflate a raw DEFLATE stream (no zlib/gzip wrapper). Grows the output
    /// buffer and retries if the first estimate was too small.
    static func inflate(_ data: Data, expectedSize: Int) -> Data? {
        guard !data.isEmpty else { return nil }
        var capacity = max(64 * 1024, expectedSize + 1024)

        for _ in 0..<8 {
            let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
            defer { dst.deallocate() }

            let written = data.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
                guard let srcBase = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(dst, capacity, srcBase, data.count, nil, COMPRESSION_ZLIB)
            }

            if written == 0 { return nil }
            if written < capacity {
                return Data(bytes: dst, count: written)
            }
            capacity *= 2 // filled the buffer exactly — probably truncated, retry bigger
        }
        return nil
    }
}
