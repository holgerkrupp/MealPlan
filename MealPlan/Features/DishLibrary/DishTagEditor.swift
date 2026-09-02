import SwiftUI
import SwiftData

/// Adds and removes a dish's free-form tags.
///
/// Typing filters the household's existing tags so the same idea doesn't end
/// up spelled three ways; anything that matches nothing is created on the spot
/// by pressing return or the "Add …" button. Tags the app derived for this
/// dish are offered separately, as outlines, until they're accepted.
@MainActor
struct DishTagEditor: View {
    @Bindable var dish: Dish
    /// Every tag already in use in the household.
    var vocabulary: [String]
    /// Automatically derived tags, offered while the dish doesn't have them.
    var suggestions: [String] = []

    @State private var draft = ""
    @FocusState private var fieldIsFocused: Bool

    private var trimmedDraft: String { DishTag.clean(draft) }

    private var completions: [String] {
        DishTag.completions(for: draft, in: vocabulary, excluding: dish.tagNames)
    }

    private var openSuggestions: [String] {
        suggestions.filter { !dish.hasTag($0) }
    }

    /// Offer to create only what isn't already a tag — and not while the field
    /// is empty.
    private var canCreateDraft: Bool {
        !trimmedDraft.isEmpty
            && !dish.hasTag(trimmedDraft)
            && DishTag.isNew(trimmedDraft, in: vocabulary)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !dish.tagNames.isEmpty {
                FlowLayout(spacing: 8) {
                    ForEach(dish.sortedTagNames, id: \.self) { tag in
                        appliedChip(tag)
                    }
                }
            }

            HStack {
                TextField(String(localized: "Add a tag"), text: $draft)
                    .focused($fieldIsFocused)
                    .submitLabel(.done)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.words)
                    #endif
                    .onSubmit { commit(trimmedDraft) }
                Button(String(localized: "Add")) { commit(trimmedDraft) }
                    .disabled(trimmedDraft.isEmpty || dish.hasTag(trimmedDraft))
            }

            if !completions.isEmpty || canCreateDraft {
                FlowLayout(spacing: 8) {
                    if canCreateDraft {
                        Button { commit(trimmedDraft) } label: {
                            chipLabel(String(localized: "Add “\(trimmedDraft)”"), systemImage: "plus")
                                .background(Color.accentColor.opacity(0.16), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                    ForEach(completions, id: \.self) { tag in
                        Button { commit(tag) } label: {
                            chipLabel(tag)
                                .background(Color.gray.opacity(0.18), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if !openSuggestions.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Suggested")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    FlowLayout(spacing: 8) {
                        ForEach(openSuggestions, id: \.self) { tag in
                            Button { commit(tag) } label: {
                                chipLabel(tag, systemImage: "plus")
                                    .overlay(
                                        Capsule().strokeBorder(.tertiary, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private func appliedChip(_ tag: String) -> some View {
        Button {
            dish.removeTag(tag)
        } label: {
            chipLabel(tag, systemImage: "xmark", trailingIcon: true)
                .background(Color.accentColor, in: Capsule())
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "Remove tag \(tag)"))
    }

    private func chipLabel(
        _ title: String,
        systemImage: String? = nil,
        trailingIcon: Bool = false
    ) -> some View {
        HStack(spacing: 4) {
            if let systemImage, !trailingIcon {
                Image(systemName: systemImage).font(.caption2)
            }
            Text(verbatim: title)
            if let systemImage, trailingIcon {
                Image(systemName: systemImage).font(.caption2)
            }
        }
        .font(.subheadline)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func commit(_ tag: String) {
        let cleaned = DishTag.clean(tag)
        guard !cleaned.isEmpty else { return }
        // Reuse the household's own spelling so "Vegan" and "vegan" stay one tag.
        dish.addTag(DishTag.canonical(cleaned, in: vocabulary))
        draft = ""
        fieldIsFocused = true
    }
}

#Preview {
    Form {
        DishTagEditor(
            dish: PreviewData.richDish,
            vocabulary: ["vegan", "schnell", "Familienessen", "Ofen", "Pasta"],
            suggestions: ["Hackfleisch", "Nudeln"]
        )
    }
    .modelContainer(PreviewData.container)
}
