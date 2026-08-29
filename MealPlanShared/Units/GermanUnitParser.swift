import Foundation

/// The result of parsing one free-text ingredient line such as
/// "200 g Mehl", "1 EL Olivenöl" or "Salz nach Geschmack".
struct ParsedIngredient: Equatable, Sendable {
    var name: String
    var quantity: Quantity?
    /// Unit label as it should be shown back to the cook ("EL", "Prise", "g").
    var displayUnit: String?
    var isApproximate: Bool = false
    var note: String?
    var rawText: String
}

/// Parses German (and common imperial) ingredient lines into a normalised
/// `ParsedIngredient`. German cooking abbreviations — EL, TL, Prise, Bund,
/// Stück, Msp, g, kg, ml, l — are treated as first-class input.
enum GermanUnitParser {

    // MARK: - Public entry point

    static func parse(_ rawInput: String) -> ParsedIngredient {
        let raw = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        var working = raw
        var note: String?

        // 1. Pull out a parenthetical hint, e.g. "1 Dose (400 g) Tomaten".
        var hint: String?
        if let open = working.firstIndex(of: "("),
           let close = working[open...].firstIndex(of: ")") {
            hint = String(working[working.index(after: open)..<close])
            working.removeSubrange(open...close)
            working = working.trimmingCharacters(in: .whitespaces)
        }

        // 2. Strip trailing "to taste"-style phrases into the note.
        for phrase in notePhrases {
            if let r = working.range(of: phrase, options: [.caseInsensitive, .backwards]),
               working.distance(from: r.upperBound, to: working.endIndex) <= 1 {
                note = append(note, String(working[r]))
                working.removeSubrange(r)
                working = working.trimmingCharacters(in: CharacterSet(charactersIn: " ,;"))
            }
        }

        // 3. Leading vague markers ("etwas", "ein wenig") with no number.
        for marker in vagueMarkers {
            if working.lowercased().hasPrefix(marker + " ") {
                note = append(note, String(working.prefix(marker.count)))
                working = String(working.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
            }
        }

        // 4. Tokenise; split a glued first token like "200g".
        var tokens = working.split(whereSeparator: { $0 == " " }).map(String.init)
        if let first = tokens.first, let (num, rest) = splitGlued(first) {
            tokens[0] = num
            if let rest { tokens.insert(rest, at: 1) }
        }

        // 5. Leading amount (supports ranges and mixed fractions).
        var amount: Double?
        var isRange = false
        if let first = tokens.first, let scanned = scanAmount(first) {
            amount = scanned.value
            isRange = scanned.isRange
            tokens.removeFirst()
            if let rangeText = scanned.rangeText {
                note = append(note, "ca. " + rangeText)
            }
            if let second = tokens.first, let frac = scanNumberComponent(second), frac < 1, !isRange {
                amount = (amount ?? 0) + frac
                tokens.removeFirst()
            }
        }

        // 6. Unit token.
        var alias: UnitAlias?
        var displayUnit: String?
        if let unitToken = tokens.first, let matched = unitAliases[unitKey(unitToken)] {
            alias = matched
            displayUnit = matched.displayLabel
            tokens.removeFirst()
            if amount == nil { amount = 1 }   // "Prise Salz" ⇒ 1 Prise
        }

        // 7. Remainder is the ingredient name.
        var name = tokens.joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " ,.-–"))
        for connector in ["an ", "von ", "vom "] where name.lowercased().hasPrefix(connector) {
            name = String(name.dropFirst(connector.count))
        }
        if name.isEmpty { name = raw }

        // 8. Build the canonical quantity.
        var quantity: Quantity?
        var approximate = isRange
        if let amount {
            if let alias {
                quantity = Quantity(value: amount * alias.factor, dimension: alias.dimension)
                approximate = approximate || alias.approximate
            } else {
                quantity = Quantity(value: amount, dimension: .count)
            }
        }

        // 9. If we only have a container count ("1 Dose"), try the hint for a
        //    concrete weight/volume.
        if let hint, quantity == nil || quantity?.dimension == .count {
            let parsedHint = parse(hint)
            if let hq = parsedHint.quantity, hq.dimension != .count {
                quantity = hq
                displayUnit = parsedHint.displayUnit
                approximate = approximate || parsedHint.isApproximate
            }
        }

        return ParsedIngredient(
            name: name,
            quantity: quantity,
            displayUnit: displayUnit,
            isApproximate: approximate,
            note: note,
            rawText: raw
        )
    }

    // MARK: - Number scanning

    static let unicodeFractions: [Character: Double] = [
        "½": 0.5, "⅓": 1.0 / 3.0, "⅔": 2.0 / 3.0, "¼": 0.25, "¾": 0.75,
        "⅕": 0.2, "⅖": 0.4, "⅗": 0.6, "⅘": 0.8, "⅛": 0.125, "⅜": 0.375,
    ]

    /// Parse a single numeric component: "1,5", "1.5", "3/4", "½", "1½".
    static func scanNumberComponent(_ input: String) -> Double? {
        let s = input.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }

        if s.count == 1, let f = unicodeFractions[s.first!] { return f }

        if let last = s.last, let f = unicodeFractions[last] {
            let head = String(s.dropLast())
            if head.isEmpty { return f }
            if let h = Double(head.replacingOccurrences(of: ",", with: ".")) { return h + f }
            return nil
        }

        if s.contains("/") {
            let parts = s.split(separator: "/")
            guard parts.count == 2,
                  let n = Double(parts[0].replacingOccurrences(of: ",", with: ".")),
                  let d = Double(parts[1].replacingOccurrences(of: ",", with: ".")),
                  d != 0 else { return nil }
            return n / d
        }

        return Double(s.replacingOccurrences(of: ",", with: "."))
    }

    /// Parse an amount token, recognising ranges ("2-3", "2–3").
    static func scanAmount(_ token: String) -> (value: Double, isRange: Bool, rangeText: String?)? {
        for sep in ["–", "—", "-"] where token.contains(sep) {
            let parts = token.components(separatedBy: sep).filter { !$0.isEmpty }
            if parts.count == 2,
               let lo = scanNumberComponent(parts[0]),
               let hi = scanNumberComponent(parts[1]) {
                _ = hi
                return (lo, true, "\(parts[0])–\(parts[1])")
            }
        }
        if let v = scanNumberComponent(token) { return (v, false, nil) }
        return nil
    }

    /// Split "200g" → ("200", "g"); returns nil when the token isn't glued.
    static func splitGlued(_ token: String) -> (number: String, unit: String?)? {
        let numeric = Set("0123456789.,/–—-" + String(Array(unicodeFractions.keys)))
        var numberPart = ""
        var rest = ""
        var inNumber = true
        for ch in token {
            if inNumber, numeric.contains(ch) {
                numberPart.append(ch)
            } else {
                inNumber = false
                rest.append(ch)
            }
        }
        guard !numberPart.isEmpty, scanNumberComponent(numberPart) != nil else { return nil }
        return (numberPart, rest.isEmpty ? nil : rest)
    }

    // MARK: - Unit table

    struct UnitAlias {
        var dimension: QuantityDimension
        var factor: Double        // amount × factor ⇒ canonical unit
        var approximate: Bool
        var displayLabel: String
    }

    static func unitKey(_ raw: String) -> String {
        raw.lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
            .folding(options: .diacriticInsensitive, locale: .init(identifier: "de"))
    }

    static let unitAliases: [String: UnitAlias] = {
        var t: [String: UnitAlias] = [:]
        func add(_ keys: [String], _ alias: UnitAlias) { for k in keys { t[unitKey(k)] = alias } }

        // Mass
        add(["g", "gr", "gramm", "gramms"], .init(dimension: .mass, factor: 1, approximate: false, displayLabel: "g"))
        add(["kg", "kilo", "kilogramm"], .init(dimension: .mass, factor: 1000, approximate: false, displayLabel: "kg"))
        add(["mg"], .init(dimension: .mass, factor: 0.001, approximate: false, displayLabel: "mg"))
        add(["dag", "dkg", "deka"], .init(dimension: .mass, factor: 10, approximate: false, displayLabel: "dag"))
        add(["pfund"], .init(dimension: .mass, factor: 500, approximate: true, displayLabel: "Pfund"))

        // Volume
        add(["ml", "milliliter"], .init(dimension: .volume, factor: 1, approximate: false, displayLabel: "ml"))
        add(["cl"], .init(dimension: .volume, factor: 10, approximate: false, displayLabel: "cl"))
        add(["dl"], .init(dimension: .volume, factor: 100, approximate: false, displayLabel: "dl"))
        add(["l", "liter", "ltr"], .init(dimension: .volume, factor: 1000, approximate: false, displayLabel: "l"))
        add(["el", "essl", "essloffel", "eslloffel", "eßlöffel"], .init(dimension: .volume, factor: 15, approximate: true, displayLabel: "EL"))
        add(["tl", "teel", "teeloffel"], .init(dimension: .volume, factor: 5, approximate: true, displayLabel: "TL"))
        add(["msp", "messerspitze"], .init(dimension: .volume, factor: 0.5, approximate: true, displayLabel: "Msp."))
        add(["prise", "prisen"], .init(dimension: .mass, factor: 0.3, approximate: true, displayLabel: "Prise"))
        add(["spritzer"], .init(dimension: .volume, factor: 2, approximate: true, displayLabel: "Spritzer"))
        add(["schuss"], .init(dimension: .volume, factor: 15, approximate: true, displayLabel: "Schuss"))
        add(["tasse", "tassen"], .init(dimension: .volume, factor: 237, approximate: true, displayLabel: "Tasse"))
        add(["becher"], .init(dimension: .volume, factor: 250, approximate: true, displayLabel: "Becher"))
        add(["glas", "glaser"], .init(dimension: .volume, factor: 200, approximate: true, displayLabel: "Glas"))

        // Count / containers
        add(["stuck", "stk", "st", "stck", "x", "×"], .init(dimension: .count, factor: 1, approximate: false, displayLabel: "Stück"))
        add(["bund"], .init(dimension: .count, factor: 1, approximate: false, displayLabel: "Bund"))
        add(["zehe", "zehen"], .init(dimension: .count, factor: 1, approximate: false, displayLabel: "Zehe"))
        add(["scheibe", "scheiben"], .init(dimension: .count, factor: 1, approximate: false, displayLabel: "Scheibe"))
        add(["kopf", "kopfe"], .init(dimension: .count, factor: 1, approximate: false, displayLabel: "Kopf"))
        add(["knolle", "knollen"], .init(dimension: .count, factor: 1, approximate: false, displayLabel: "Knolle"))
        add(["dose", "dosen"], .init(dimension: .count, factor: 1, approximate: false, displayLabel: "Dose"))
        add(["packung", "packungen", "pkg", "pck", "packchen", "paket", "beutel"], .init(dimension: .count, factor: 1, approximate: false, displayLabel: "Packung"))
        add(["flasche", "flaschen"], .init(dimension: .count, factor: 1, approximate: false, displayLabel: "Flasche"))
        add(["handvoll"], .init(dimension: .count, factor: 1, approximate: true, displayLabel: "Handvoll"))

        // Imperial
        add(["cup", "cups"], .init(dimension: .volume, factor: 236.588, approximate: true, displayLabel: "cup"))
        add(["oz", "ounce", "ounces"], .init(dimension: .mass, factor: 28.3495, approximate: false, displayLabel: "oz"))
        add(["lb", "lbs", "pound", "pounds"], .init(dimension: .mass, factor: 453.592, approximate: false, displayLabel: "lb"))
        add(["tbsp", "tablespoon", "tablespoons"], .init(dimension: .volume, factor: 14.787, approximate: true, displayLabel: "tbsp"))
        add(["tsp", "teaspoon", "teaspoons"], .init(dimension: .volume, factor: 4.929, approximate: true, displayLabel: "tsp"))
        add(["pinch"], .init(dimension: .mass, factor: 0.3, approximate: true, displayLabel: "pinch"))

        return t
    }()

    // MARK: - Phrase tables

    static let notePhrases = [
        "nach geschmack", "je nach geschmack", "nach belieben", "nach bedarf",
        "zum bestreuen", "zum garnieren", "zum servieren", "zum abschmecken",
        "zum braten", "zum frittieren", "n. b.", "n.b.", "optional",
    ]

    static let vagueMarkers = ["etwas", "etw", "ein wenig", "ein bisschen", "bisschen", "wenig"]

    private static func append(_ base: String?, _ addition: String) -> String {
        let clean = addition.trimmingCharacters(in: CharacterSet(charactersIn: " ,;"))
        guard let base, !base.isEmpty else { return clean }
        return base + ", " + clean
    }
}
