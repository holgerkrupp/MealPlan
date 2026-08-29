import SwiftUI

/// A stand-in picture for a dish that has no photo: either an emoji or an
/// SF Symbol. Stored on `Dish.glyphRaw` as one prefixed string so it travels
/// as a single CloudKit field.
enum DishGlyph: Hashable, Sendable {
    case emoji(String)
    case symbol(String)

    private static let emojiPrefix = "emoji:"
    private static let symbolPrefix = "symbol:"

    var rawValue: String {
        switch self {
        case .emoji(let value): Self.emojiPrefix + value
        case .symbol(let name): Self.symbolPrefix + name
        }
    }

    init?(rawValue: String) {
        if rawValue.hasPrefix(Self.emojiPrefix) {
            let value = String(rawValue.dropFirst(Self.emojiPrefix.count))
            guard !value.isEmpty else { return nil }
            self = .emoji(value)
        } else if rawValue.hasPrefix(Self.symbolPrefix) {
            let name = String(rawValue.dropFirst(Self.symbolPrefix.count))
            guard !name.isEmpty else { return nil }
            self = .symbol(name)
        } else {
            return nil
        }
    }

    /// The SF Symbol name, when this glyph is a symbol.
    var symbolName: String? {
        if case .symbol(let name) = self { return name }
        return nil
    }

    /// The emoji, when this glyph is one.
    var emoji: String? {
        if case .emoji(let value) = self { return value }
        return nil
    }
}

// MARK: - Tint

extension DishGlyph {
    /// The placeholder tints, in the same spirit as the meal-card palette.
    static let palette: [Color] = [
        .orange, .blue, .green, .purple, .pink, .teal, .indigo, .brown, .mint, .red,
    ]

    /// A stable colour for a dish, derived from its name (djb2) so the same
    /// dish always looks the same on every device without storing anything.
    static func tint(forName name: String) -> Color {
        guard !name.isEmpty else { return .gray }
        var hash: UInt64 = 5381
        for byte in name.utf8 { hash = (hash &* 33) ^ UInt64(byte) }
        return palette[Int(hash % UInt64(palette.count))]
    }
}

// MARK: - Emoji detection

extension Character {
    /// True for characters that render as emoji (rather than plain text).
    var isEmojiGlyph: Bool {
        guard let scalar = unicodeScalars.first else { return false }
        return scalar.properties.isEmojiPresentation
            || (scalar.properties.isEmoji && unicodeScalars.count > 1)
    }
}

extension String {
    /// True when the string is exactly one emoji — what the placeholder field accepts.
    var isSingleEmoji: Bool {
        count == 1 && first?.isEmojiGlyph == true
    }
}
