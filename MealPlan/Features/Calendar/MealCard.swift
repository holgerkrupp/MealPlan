import SwiftUI
import SwiftData

/// One meal (Breakfast, Lunch, …) on one day, shown as its own card in the
/// day's row. Each meal gets a stable accent colour; an empty card shows the
/// meal's glyph in the background, a filled one shows the dish photo edge to
/// edge. Handles adding dishes, drag-and-drop rescheduling and the per-entry
/// quick actions.
@MainActor
struct MealCard: View {
    let date: Date
    let mealKey: String
    let title: String
    let symbolName: String
    let entries: [MealPlanEntry]

    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var context
    @Environment(\.colorScheme) private var colorScheme

    @State private var showingPicker = false
    @State private var selectedEntry: MealPlanEntry?
    @State private var isTargeted = false
    /// Bumped by every drop this card accepts, to drive the haptic.
    @State private var acceptedDrops = 0
    /// Presented here rather than from inside the picker: on macOS the picker
    /// is a popover, and a sheet put up by a popover goes down with it.
    @State private var newDishToEdit: Dish?

    private static let cornerRadius: CGFloat = 14
    private static let palette: [Color] = [
        .orange, .blue, .green, .purple, .pink, .teal, .indigo, .brown, .mint, .red,
    ]

    /// Stable accent colour derived from the meal's key (djb2 hash).
    private var accent: Color {
        var hash: UInt64 = 5381
        for byte in mealKey.utf8 { hash = (hash &* 33) ^ UInt64(byte) }
        return Self.palette[Int(hash % UInt64(Self.palette.count))]
    }

    /// The photo to use as the card's full background, if any dish has one.
    private var backdropData: Data? {
        entries.lazy.compactMap { $0.dish?.primaryImageData }.first
    }

    private var onImage: Bool { backdropData != nil }

    /// The placeholder glyph of the first planned dish that has one. Used as
    /// the card's backdrop in place of the meal symbol, so a dish without a
    /// photo still reads at a glance. Keeps the meal's accent colour so the
    /// card's colour language stays per-meal.
    private var backdropGlyph: DishGlyph? {
        if let glyph = entries.lazy.compactMap({ $0.dish?.glyph }).first { return glyph }
        // A meal that is only "we're eating out" gets the storefront instead of
        // the meal's own symbol, so the card reads at a glance.
        if !entries.isEmpty, entries.allSatisfy(\.isEatingOut) { return .symbol("storefront") }
        return nil
    }

    /// A card only claims the height it needs: an empty one is just its header
    /// plus the add button, a planned one keeps enough room for the photo
    /// backdrop to read. Cards in the same grid row still equalise.
    private var minCardHeight: CGFloat {
        entries.isEmpty ? 68 : 108
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header

            if entries.isEmpty {
                Spacer(minLength: 0)
                Button {
                    showingPicker = true
                } label: {
                    Label(String(localized: "Add a meal"), systemImage: "plus")
                        .font(.subheadline.weight(.medium))
                        .padding(.vertical, 6)
                        .padding(.horizontal, 10)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(appState.isGuest)
            } else {
                ForEach(entries) { entry in
                    HStack(spacing: 4) {
                        // Tappable row, not a `Button`, so that `.draggable`
                        // below still gets the mouse-down on macOS — a button
                        // swallows it and the meal could never be dragged to
                        // another day. Same reasoning as `DishSidebarView`.
                        //
                        // The context menu has to sit on that very same view:
                        // on iPhone menu and drag both begin with a long press,
                        // and only when they share a view does the system hand
                        // the press to the menu and a drag out of it to the
                        // meal. Attached one level up, as it used to be, the
                        // menu won every press and nothing could be dragged.
                        entryRow(entry)
                            .contentShape(Rectangle())
                            .onTapGesture { selectedEntry = entry }
                            .draggable(dragPayload(entry)) { dragPreview(entry) }
                            .contextMenu { entryMenu(entry) }
                            .accessibilityElement(children: .combine)
                            .accessibilityAddTraits(.isButton)
                            .accessibilityAction { selectedEntry = entry }
                            // Dragging needs an equivalent for VoiceOver and
                            // the keyboard: the quick actions sheet moves the
                            // same meal without a pointer.
                            .accessibilityAction(named: String(localized: "Move to another day or meal…")) {
                                selectedEntry = entry
                            }

                        if !appState.isGuest {
                            Button {
                                remove(entry)
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .font(.body)
                                    .foregroundStyle(onImage ? AnyShapeStyle(.white.opacity(0.9)) : AnyShapeStyle(.secondary))
                                    .padding(.vertical, 2)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(String(localized: "Remove \(entry.displayTitle)"))
                        }
                    }
                }
                if !appState.isGuest {
                    Button {
                        showingPicker = true
                    } label: {
                        Label(String(localized: "Add another"), systemImage: "plus")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(onImage ? .white : Color.primary)
                            .opacity(0.9)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(10)
        .frame(
            minWidth: 0, maxWidth: .infinity,
            minHeight: minCardHeight,
            alignment: .topLeading
        )
        // Drawn as a background so the oversized backdrop glyph can't set the
        // card's height — the content alone decides how tall the card is.
        .background { cardBackground }
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .strokeBorder(
                    isTargeted ? Color.accentColor : accent.opacity(onImage ? 0 : 0.35),
                    lineWidth: isTargeted ? 2.5 : 1
                )
        )
        .contentShape(Rectangle())
        .dropDestination(for: DishReference.self) { refs, _ in
            handleDrop(refs)
        } isTargeted: { isTargeted = $0 }
        #if os(iOS)
        // The card a meal came from is often off screen by the time it lands,
        // so the drop is confirmed by feel as well as by the plan changing.
        .sensoryFeedback(.success, trigger: acceptedDrops)
        #endif
        // A popover on the Mac, so clicking anywhere outside puts it away —
        // a modal sheet there would trap the click and beep instead.
        #if os(macOS)
        .popover(isPresented: $showingPicker, arrowEdge: .top) { picker }
        #else
        .sheet(isPresented: $showingPicker) { picker }
        #endif
        .sheet(item: $selectedEntry) { entry in
            EntryQuickActionsSheet(entry: entry)
        }
        .sheet(item: $newDishToEdit) { dish in
            NavigationStack { DishEditorView(dish: dish, isNew: true) }
        }
    }

    private var picker: some View {
        DishPickerView(
            date: date,
            mealKey: mealKey,
            mealTitle: title,
            mealSymbol: symbolName,
            onEditNewDish: { newDishToEdit = $0 }
        )
    }

    // MARK: - Background

    @ViewBuilder
    private var cardBackground: some View {
        if let backdropData, let image = Image(data: backdropData) {
            image
                .resizable()
                .scaledToFill()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(
                    LinearGradient(
                        colors: [.black.opacity(0.15), .black.opacity(0.30), .black.opacity(0.70)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .clipped()
        } else {
            ZStack(alignment: .bottomTrailing) {
                Rectangle().fill(.background)
                Rectangle().fill(accent.opacity(colorScheme == .dark ? 0.28 : 0.16))
                backdropSymbol
                    .offset(x: 22, y: 20)
            }
        }
    }

    /// The oversized glyph behind an empty / photo-less card: the dish's own
    /// emoji or symbol when it has one, otherwise the meal's symbol.
    @ViewBuilder
    private var backdropSymbol: some View {
        switch backdropGlyph {
        case .emoji(let value):
            Text(value)
                .font(.system(size: 88))
                .opacity(colorScheme == .dark ? 0.45 : 0.35)
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: 96, weight: .semibold))
                .foregroundStyle(accent.opacity(colorScheme == .dark ? 0.30 : 0.22))
        case nil:
            Image(systemName: symbolName)
                .font(.system(size: 96, weight: .semibold))
                .foregroundStyle(accent.opacity(colorScheme == .dark ? 0.30 : 0.22))
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: symbolName)
                .font(.caption)
            Text(title)
                .font(.caption.weight(.bold))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .foregroundStyle(onImage ? AnyShapeStyle(.white) : AnyShapeStyle(accent))
        .shadow(color: .black.opacity(onImage ? 0.5 : 0), radius: 2, y: 1)
    }

    // MARK: - Drag and drop

    /// The payload for dragging a planned meal. It carries the entry, so
    /// dropping it elsewhere on the plan moves this meal rather than planning a
    /// second helping of the same dish. `name` doubles as the plain-text
    /// representation when the drag ends up in another app.
    private func dragPayload(_ entry: MealPlanEntry) -> DishReference {
        DishReference(
            dishUUID: entry.dish?.uuid ?? UUID(),
            name: entry.displayTitle,
            sourceEntryUUID: entry.uuid
        )
    }

    /// What travels under the finger or pointer. Worth spelling out: the
    /// automatic preview snapshots the row as it sits on the card, which on a
    /// photo card is white text over nothing.
    private func dragPreview(_ entry: MealPlanEntry) -> some View {
        HStack(spacing: 8) {
            if entry.dish != nil {
                DishThumbnail(dish: entry.dish, size: 28, cornerRadius: 6)
            } else {
                Image(systemName: "storefront")
                    .font(.subheadline)
                    .foregroundStyle(accent)
            }
            Text(entry.displayTitle)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .foregroundStyle(Color.primary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.background, in: Capsule())
        .overlay(Capsule().strokeBorder(accent.opacity(0.6), lineWidth: 1))
    }

    private func handleDrop(_ refs: [DishReference]) -> Bool {
        guard !appState.isGuest, let ref = refs.first else { return false }
        let accepted = MealPlanner.drop(
            ref, onto: date, mealKey: mealKey,
            household: appState.currentHousehold,
            memberName: appState.currentMemberName,
            context: context
        )
        if accepted { acceptedDrops += 1 }
        return accepted
    }

    // MARK: - Context menu

    @ViewBuilder
    private func entryMenu(_ entry: MealPlanEntry) -> some View {
        Button {
            MealPlanner.repeatEntry(entry, weeksAhead: 1, memberName: appState.currentMemberName, context: context)
        } label: {
            Label(String(localized: "Repeat next week"), systemImage: "arrow.uturn.forward")
        }
        Button {
            selectedEntry = entry
        } label: {
            Label(String(localized: "Edit / reschedule…"), systemImage: "slider.horizontal.3")
        }
        Button(role: .destructive) {
            remove(entry)
        } label: {
            Label(String(localized: "Remove"), systemImage: "trash")
        }
    }

    private func remove(_ entry: MealPlanEntry) {
        let name = entry.displayTitle
        context.delete(entry)
        try? context.save()
        SharedStore.reloadWidgets()
        let undo = context.undoManager
        appState.offerUndo(String(localized: "Removed “\(name)”")) {
            undo?.undo(); try? context.save()
        }
    }

    // MARK: - Entry row

    private func entryRow(_ entry: MealPlanEntry) -> some View {
        let hasOwnImage = entry.dish?.primaryImageData != nil
        let isEatingOut = entry.dish == nil && entry.isEatingOut

        return HStack(spacing: 8) {
            if isEatingOut {
                Image(systemName: "storefront")
                    .font(onImage ? .caption2 : .body)
                    .foregroundStyle(onImage ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(accent))
                    .frame(width: onImage ? 18 : 34)
            } else if !onImage {
                DishThumbnail(dish: entry.dish, size: 34, cornerRadius: 8)
            } else if !hasOwnImage {
                switch entry.dish?.glyph {
                case .emoji(let value):
                    Text(value).font(.caption).frame(width: 18)
                case .symbol(let name):
                    Image(systemName: name)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: 18)
                case nil:
                    Image(systemName: "fork.knife")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: 18)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.displayTitle)
                    .font(.subheadline.weight(onImage ? .semibold : .regular))
                    .lineLimit(2)
                    .strikethrough(entry.skipped)
                    .foregroundStyle(onImage ? AnyShapeStyle(.white) : AnyShapeStyle(entry.skipped ? Color.secondary : Color.primary))

                HStack(spacing: 6) {
                    if entry.routineUUID != nil {
                        Image(systemName: "repeat")
                    }
                    if entry.servingsOverride != nil {
                        Label(String(localized: "\(entry.effectiveServings)"), systemImage: "person.2")
                            .labelStyle(.titleAndIcon)
                    }
                    if entry.prepReminder {
                        Image(systemName: "bell")
                    }
                    if let reaction = entry.reaction {
                        Image(systemName: reaction.symbolName)
                            .foregroundStyle(onImage ? .white : (reaction == .down ? .red : .yellow))
                    }
                    if entry.dish?.needsReview == true {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(onImage ? .white : .orange)
                    }
                }
                .font(.caption2)
                .foregroundStyle(onImage ? .white.opacity(0.9) : Color.secondary)
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)
        }
        .shadow(color: .black.opacity(onImage ? 0.45 : 0), radius: 2, y: 1)
    }
}

#Preview("Planned") {
    MealCard(
        date: .now,
        mealKey: PreviewData.mealType.key,
        title: PreviewData.mealType.name,
        symbolName: PreviewData.mealType.symbolName,
        entries: PreviewData.entries(on: .now, mealKey: PreviewData.mealType.key)
    )
    .frame(width: 220)
    .padding()
    .environment(AppState.preview)
    .modelContainer(PreviewData.container)
}

#Preview("Empty") {
    MealCard(
        date: .now,
        mealKey: MealSlot.lunch.rawValue,
        title: MealSlot.lunch.localizedName,
        symbolName: MealSlot.lunch.symbolName,
        entries: []
    )
    .frame(width: 220)
    .padding()
    .environment(AppState.preview)
    .modelContainer(PreviewData.container)
}
