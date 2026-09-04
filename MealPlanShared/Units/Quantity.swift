import Foundation

/// An amount in the canonical unit for its dimension:
/// mass → grams, volume → millilitres, count → pieces.
struct Quantity: Equatable, Sendable {
    var value: Double
    var dimension: QuantityDimension

    init(value: Double, dimension: QuantityDimension) {
        self.value = value
        self.dimension = dimension
    }

    static func grams(_ v: Double) -> Quantity { .init(value: v, dimension: .mass) }
    static func millilitres(_ v: Double) -> Quantity { .init(value: v, dimension: .volume) }
    static func pieces(_ v: Double) -> Quantity { .init(value: v, dimension: .count) }

    /// Add two quantities of the same dimension. Returns `nil` for a mismatch.
    func adding(_ other: Quantity) -> Quantity? {
        guard other.dimension == dimension else { return nil }
        return Quantity(value: value + other.value, dimension: dimension)
    }

    func scaled(by factor: Double) -> Quantity {
        Quantity(value: value * factor, dimension: dimension)
    }

    /// Round-trippable "<dimension>:<value>", so a handful of quantities can be
    /// kept in a plain `[String]` on a SwiftData model.
    var encoded: String {
        "\(dimension.rawValue):\(value)"
    }

    init?(encoded: String) {
        let parts = encoded.split(separator: ":", maxSplits: 1)
        guard parts.count == 2,
              let dimension = QuantityDimension(rawValue: String(parts[0])),
              let value = Double(parts[1])
        else { return nil }
        self.init(value: value, dimension: dimension)
    }
}
