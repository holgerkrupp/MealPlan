import SwiftUI
import SwiftData
import SFSymbolSelector

/// Symbol lists for dish placeholders. Food symbols come first, then the
/// whole `SFSymbolCatalog` so anything else is still reachable — the selector
/// de-duplicates, so listing a symbol here just promotes it to the front.
enum DishSymbolCatalog {
    static let food = [
        "fork.knife", "carrot.fill", "fish.fill", "leaf.fill", "birthday.cake.fill",
        "cup.and.saucer.fill", "mug.fill", "wineglass.fill", "waterbottle.fill",
        "takeoutbag.and.cup.and.straw.fill", "popcorn.fill", "basket.fill", "cart.fill",
        "flame.fill", "bird.fill", "hare.fill", "tree.fill", "drop.fill", "allergens.fill",
    ]

    static let foodFirst = food + SFSymbolCatalog.commonSymbols
}

/// Curated emoji for dishes. The free-entry field takes anything else.
enum DishEmojiCatalog {
    static let common = [
        "🍝", "🍕", "🍔", "🌮", "🥗", "🍜", "🍲", "🥘", "🍛", "🍚",
        "🍣", "🐟", "🍤", "🥩", "🍗", "🥓", "🌭", "🥪", "🫓", "🥙",
        "🥞", "🧇", "🍳", "🥐", "🍞", "🥖", "🧀", "🥚", "🥣", "🥯",
        "🥔", "🥕", "🌽", "🥦", "🍅", "🍆", "🥑", "🫑", "🍄", "🧅",
        "🍎", "🍌", "🍓", "🫐", "🍇", "🍊", "🍋", "🍉", "🍑", "🥭",
        "🍰", "🧁", "🍪", "🍫", "🍦", "🍮", "🥧", "🍯", "☕️", "🍵",
    ]
}

/// Picks the emoji or SF Symbol shown wherever a dish has no photo.
///
/// The app suggests one from the dish's name; any choice made here is the
/// user's and stops the suggestion from following the name any further, until
/// they hand it back with "Suggest automatically".
@MainActor
struct DishGlyphPicker: View {
    @Bindable var dish: Dish
    /// Tints the preview and the symbol grid, matching how the dish renders.
    var tint: Color

    @State private var emojiEntry = ""

    private var glyph: DishGlyph? { dish.glyph }

    private var symbolBinding: Binding<String> {
        Binding(
            get: { dish.glyph?.symbolName ?? "" },
            set: { dish.setGlyphManually($0.isEmpty ? nil : .symbol($0)) }
        )
    }

    var body: some View {
        preview
        emojiRow
        SFSymbolSelector(
            selection: symbolBinding,
            suggestedSymbolName: glyph?.symbolName ?? "",
            tint: tint,
            symbols: DishSymbolCatalog.foodFirst
        )
    }

    // MARK: - Preview

    @ViewBuilder
    private var preview: some View {
        HStack(spacing: 12) {
            DishThumbnail(data: nil, glyph: glyph, tint: tint, size: 56, cornerRadius: 12)

            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "Placeholder"))
                    .font(.subheadline.weight(.medium))
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            if glyph != nil {
                Button(String(localized: "Clear"), systemImage: "xmark.circle.fill") {
                    dish.setGlyphManually(nil)
                    emojiEntry = ""
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }

        if !dish.glyphIsAuto {
            Button(String(localized: "Suggest automatically"), systemImage: "wand.and.stars") {
                dish.glyphIsAuto = true
                dish.refreshAutoGlyph()
                emojiEntry = ""
            }
            .font(.subheadline)
        }
    }

    private var statusText: String {
        if dish.glyphIsAuto {
            return String(localized: "Suggested from the dish name")
        }
        return glyph == nil
            ? String(localized: "No placeholder — shows a generic icon")
            : String(localized: "Used everywhere this dish has no photo")
    }

    // MARK: - Emoji

    private var emojiRow: some View {
        DisclosureGroup(String(localized: "Emoji")) {
            VStack(alignment: .leading, spacing: 10) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 38), spacing: 10)], spacing: 10) {
                    ForEach(DishEmojiCatalog.common, id: \.self) { emoji in
                        Button {
                            dish.setGlyphManually(.emoji(emoji))
                            emojiEntry = ""
                        } label: {
                            Text(emoji)
                                .font(.system(size: 20))
                                .frame(width: 34, height: 34)
                                .background(
                                    glyph?.emoji == emoji ? tint.opacity(0.35) : tint.opacity(0.10),
                                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                                )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(emoji)
                    }
                }

                HStack {
                    TextField(String(localized: "Or type any emoji"), text: $emojiEntry)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .onChange(of: emojiEntry) { _, value in
                            // Keep only the last emoji typed, so pasting a word
                            // or a whole sentence can't become a placeholder.
                            if let last = value.last, String(last).isSingleEmoji {
                                dish.setGlyphManually(.emoji(String(last)))
                                emojiEntry = String(last)
                            } else if !value.isEmpty {
                                emojiEntry = ""
                            }
                        }
                }
            }
            .padding(.vertical, 6)
        }
    }
}

#Preview {
    Form {
        DishGlyphPicker(dish: PreviewData.dish, tint: DishGlyph.tint(forName: PreviewData.dish.name))
    }
    .modelContainer(PreviewData.container)
}
