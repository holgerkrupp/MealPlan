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
                        Button {
                            selectedEntry = entry
                        } label: {
                            entryRow(entry)
                        }
                        .buttonStyle(.plain)

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
                    .draggable(DishReference(
                        dishUUID: entry.dish?.uuid ?? UUID(),
                        name: entry.dish?.name ?? "",
                        sourceEntryUUID: entry.uuid
                    ))
                    .contextMenu { entryMenu(entry) }
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
        .sheet(isPresented: $showingPicker) {
            NavigationStack { DishPickerView(date: date, mealKey: mealKey, mealTitle: title) }
        }
        .sheet(item: $selectedEntry) { entry in
            EntryQuickActionsSheet(entry: entry)
        }
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

    // MARK: - Drop

    private func handleDrop(_ refs: [DishReference]) -> Bool {
        guard !appState.isGuest, let ref = refs.first else { return false }

        if let sourceUUID = ref.sourceEntryUUID,
           let entry = fetchEntry(uuid: sourceUUID) {
            MealPlanner.move(entry, to: date, mealKey: mealKey, memberName: appState.currentMemberName, context: context)
            return true
        }
        if let dish = fetchDish(uuid: ref.dishUUID) {
            MealPlanner.plan(
                dish: dish, on: date, mealKey: mealKey,
                household: appState.currentHousehold,
                memberName: appState.currentMemberName,
                context: context
            )
            return true
        }
        return false
    }

    private func fetchDish(uuid: UUID) -> Dish? {
        try? context.fetch(FetchDescriptor<Dish>(predicate: #Predicate { $0.uuid == uuid })).first
    }

    private func fetchEntry(uuid: UUID) -> MealPlanEntry? {
        try? context.fetch(FetchDescriptor<MealPlanEntry>(predicate: #Predicate { $0.uuid == uuid })).first
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
