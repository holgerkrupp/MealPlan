import SwiftUI

/// One scrollable row of the household's most-used tags, for narrowing a dish
/// list without opening the filter menu. Tapping toggles; several tags stack,
/// so the list narrows the way it does in the menu.
///
/// The row stays in usage order while you tap — chips never rearrange under
/// your finger — and any tag chosen in the menu that isn't popular enough to
/// be listed is pinned in front so an active filter is always visible.
@MainActor
struct TagFilterStrip: View {
    @Binding var filter: DishFilter
    /// The household's tags, most-used first.
    var tags: [String]
    /// Inset of the row's content. Zero where the container already pads.
    var horizontalPadding: CGFloat = 16

    private var chips: [String] {
        let offScreen = filter.tags.filter { selected in
            !tags.contains { DishTag.areSame($0, selected) }
        }
        return DishTag.sorted(Array(offScreen)) + tags
    }

    var body: some View {
        if !chips.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(chips, id: \.self) { tag in
                        chip(tag)
                    }
                }
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, 2)
            }
        }
    }

    private func chip(_ tag: String) -> some View {
        let isOn = filter.isSelected(tag: tag)
        return Button {
            filter.toggle(tag: tag)
        } label: {
            Text(verbatim: tag)
                .font(.caption.weight(isOn ? .semibold : .regular))
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary.opacity(0.6)),
                    in: Capsule()
                )
                .foregroundStyle(isOn ? AnyShapeStyle(.white) : AnyShapeStyle(Color.primary))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }
}

#Preview {
    @Previewable @State var filter = DishFilter()
    VStack(alignment: .leading) {
        TagFilterStrip(filter: $filter, tags: ["vegan", "schnell", "Ofen", "Familienessen", "Pasta"])
        Text(verbatim: DishTag.sorted(Array(filter.tags)).joined(separator: " · "))
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
    }
    .padding(.vertical)
}
