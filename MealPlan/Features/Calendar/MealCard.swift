import SwiftUI
import SwiftData
import AppIntents

/// The small, value-only representation the calendar needs to draw a meal.
/// Keeping this boundary between SwiftData and SwiftUI is important: a lazy
/// card can outlive, or be rebuilt around, the model that produced it without
/// retaining a faulting object graph on the main actor.
struct DishValueSnapshot: Identifiable, Sendable {
    let uuid: UUID
    let persistentID: PersistentIdentifier?
    let modifiedAt: Date
    let name: String
    let glyph: DishGlyph?
    let needsReview: Bool

    var id: UUID { uuid }

    init(_ dish: Dish) {
        uuid = dish.uuid
        persistentID = DishPhotoLoading.persistentID(for: dish)
        modifiedAt = dish.modifiedAt
        name = dish.name
        glyph = dish.glyph
        needsReview = dish.needsReview
    }
}

struct MealPlanEntrySnapshot: Identifiable, Sendable {
    let uuid: UUID
    let modifiedAt: Date
    let date: Date
    let mealKey: String
    let sortIndex: Int
    let servingsOverride: Int?
    let skipped: Bool
    let prepReminder: Bool
    let plannedByName: String?
    let reactionRaw: String?
    let routineUUID: UUID?
    let isEatingOut: Bool
    let placeName: String?
    let dish: DishValueSnapshot?

    var id: UUID { uuid }
    var reaction: Reaction? { reactionRaw.flatMap(Reaction.init(rawValue:)) }
    var displayTitle: String {
        if let dish { return dish.name }
        if isEatingOut { return placeName ?? String(localized: "Eating out") }
        return String(localized: "(dish removed)")
    }

    init(_ entry: MealPlanEntry) {
        uuid = entry.uuid
        modifiedAt = entry.modifiedAt
        date = entry.date
        mealKey = entry.mealKey
        sortIndex = entry.sortIndex
        servingsOverride = entry.servingsOverride
        skipped = entry.skipped
        prepReminder = entry.prepReminder
        plannedByName = entry.plannedByName
        reactionRaw = entry.reactionRaw
        routineUUID = entry.routineUUID
        isEatingOut = entry.isEatingOut
        placeName = entry.placeName
        dish = entry.dish.map(DishValueSnapshot.init)
    }
}

/// Value-only undo data for a planned meal. SwiftData's automatic undo keeps
/// the deleted model graph alive while saving; on recent OS releases that can
/// trap while creating an undo snapshot. Restoring from values preserves the
/// UI undo behavior without retaining the deleted `MealPlanEntry`.
struct MealPlanEntryUndoSnapshot {
    struct CookedLogSnapshot {
        let uuid: UUID
        let modifiedAt: Date
        let date: Date
        let dishName: String?
        let servings: Int?
        let photoData: Data?
    }

    let uuid: UUID
    let modifiedAt: Date
    let placementModifiedAt: Date
    let contentModifiedAt: Date
    let date: Date
    let mealSlotRaw: String
    let servingsOverride: Int?
    let note: String?
    let sortIndex: Int
    let reactionRaw: String?
    let skipped: Bool
    let prepReminder: Bool
    let plannedByName: String?
    let lastEditedByName: String?
    let lastEditedDate: Date?
    let participatingMemberUUIDs: [String]
    let isEatingOut: Bool
    let placeName: String?
    let placeAddress: String?
    let placeLatitude: Double?
    let placeLongitude: Double?
    let routineUUID: UUID?
    let dishUUID: UUID?
    let householdUUID: UUID?
    let cookedLog: CookedLogSnapshot?

    init(_ entry: MealPlanEntry) {
        uuid = entry.uuid
        modifiedAt = entry.modifiedAt
        placementModifiedAt = entry.placementModifiedAt
        contentModifiedAt = entry.contentModifiedAt
        date = entry.date
        mealSlotRaw = entry.mealSlotRaw
        servingsOverride = entry.servingsOverride
        note = entry.note
        sortIndex = entry.sortIndex
        reactionRaw = entry.reactionRaw
        skipped = entry.skipped
        prepReminder = entry.prepReminder
        plannedByName = entry.plannedByName
        lastEditedByName = entry.lastEditedByName
        lastEditedDate = entry.lastEditedDate
        participatingMemberUUIDs = entry.participatingMemberUUIDs
        isEatingOut = entry.isEatingOut
        placeName = entry.placeName
        placeAddress = entry.placeAddress
        placeLatitude = entry.placeLatitude
        placeLongitude = entry.placeLongitude
        routineUUID = entry.routineUUID
        dishUUID = entry.dish?.uuid
        householdUUID = entry.household?.uuid
        cookedLog = entry.cookedLog.map {
            CookedLogSnapshot(
                uuid: $0.uuid,
                modifiedAt: $0.modifiedAt,
                date: $0.date,
                dishName: $0.dishName,
                servings: $0.servings,
                photoData: $0.photoData
            )
        }
    }

    @MainActor
    func restore(in context: ModelContext) throws {
        let existing = try context.fetch(FetchDescriptor<MealPlanEntry>())
        guard !existing.contains(where: { $0.uuid == uuid }) else { return }
        let households = try context.fetch(FetchDescriptor<Household>())
        let household = households.first { $0.uuid == householdUUID }
        let dishes = try context.fetch(FetchDescriptor<Dish>())
        let dish = dishes.first { $0.uuid == dishUUID }

        let entry = MealPlanEntry(date: date, mealKey: mealSlotRaw, dish: dish)
        entry.uuid = uuid
        entry.modifiedAt = modifiedAt
        entry.placementModifiedAt = placementModifiedAt
        entry.contentModifiedAt = contentModifiedAt
        entry.servingsOverride = servingsOverride
        entry.note = note
        entry.sortIndex = sortIndex
        entry.reactionRaw = reactionRaw
        entry.skipped = skipped
        entry.prepReminder = prepReminder
        entry.plannedByName = plannedByName
        entry.lastEditedByName = lastEditedByName
        entry.lastEditedDate = lastEditedDate
        entry.participatingMemberUUIDs = participatingMemberUUIDs
        entry.isEatingOut = isEatingOut
        entry.placeName = placeName
        entry.placeAddress = placeAddress
        entry.placeLatitude = placeLatitude
        entry.placeLongitude = placeLongitude
        entry.routineUUID = routineUUID
        entry.household = household
        context.insert(entry)

        if let cookedLog {
            let log = CookedLog(date: cookedLog.date, dish: dish, servings: cookedLog.servings)
            log.uuid = cookedLog.uuid
            log.modifiedAt = cookedLog.modifiedAt
            log.dishName = cookedLog.dishName
            log.photoData = cookedLog.photoData
            log.entry = entry
            log.household = household
            context.insert(log)
        }
    }
}

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
    let entries: [MealPlanEntrySnapshot]
    var nutritionSummary: WeekNutritionSummary? = nil

    @Environment(AppState.self) private var appState
    @Environment(PurchaseManager.self) private var purchaseManager
    @Environment(\.modelContext) private var context
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    @State private var showingPicker = false
    @State private var selectedEntry: MealPlanEntry?
    @State private var isTargeted = false
    /// Bumped by every drop this card accepts, to drive the haptic.
    @State private var acceptedDrops = 0
    /// Presented here rather than from inside the picker: on macOS the picker
    /// is a popover, and a sheet put up by a popover goes down with it.
    @State private var newDishToEdit: Dish?
    @State private var showingPaywall = false

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

    private var isPlanningLocked: Bool { !purchaseManager.canPlan(on: date) }

    var body: some View {
        // The snapshot contains only scalar dish metadata and its persistent
        // identity. Photo bytes are resolved by CachedDishPhoto off the main
        // actor.
        let backdropDish = entries.lazy.compactMap(\.dish).first
        let showsBackdrop = backdropDish != nil

        return VStack(alignment: .leading, spacing: 8) {
            header(showsBackdrop: showsBackdrop)

            if entries.isEmpty {
                Spacer(minLength: 0)
                Button {
                    showPlanningUI()
                } label: {
                    Label(
                        isPlanningLocked ? String(localized: "Unlock App") : String(localized: "Add a meal"),
                        systemImage: isPlanningLocked ? "lock.fill" : "plus"
                    )
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
                        entryRow(entry, showsBackdrop: showsBackdrop)
                            #if MEALPLAN_ENABLE_OS27_APP_INTENTS
                            .appEntityIdentifier(EntityIdentifier(
                                for: MealPlanEntryEntity.self,
                                identifier: entry.uuid
                            ))
                            #endif
                            .contentShape(Rectangle())
                            .onTapGesture { showDetails(for: entry) }
                            .draggable(dragPayload(entry)) { dragPreview(entry) }
                            .contextMenu { entryMenu(entry) }
                            .accessibilityElement(children: .combine)
                            .accessibilityAddTraits(.isButton)
                            .accessibilityAction { showDetails(for: entry) }
                            // Dragging needs an equivalent for VoiceOver and
                            // the keyboard: the quick actions sheet moves the
                            // same meal without a pointer.
                            .accessibilityAction(named: String(localized: "Move to another day or meal…")) {
                                showDetails(for: entry)
                            }

                        if !appState.isGuest {
                            Button {
                                remove(entry)
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .font(.body)
                                    .foregroundStyle(showsBackdrop ? AnyShapeStyle(.white.opacity(0.9)) : AnyShapeStyle(.secondary))
                                    .padding(.vertical, 2)
                            }
                            .buttonStyle(.plain)
                            .help(String(localized: "Remove from the plan"))
                            .accessibilityLabel(String(localized: "Remove \(entry.displayTitle)"))
                        }
                    }
                }
                if !appState.isGuest {
                    Button {
                        showPlanningUI()
                    } label: {
                        Label(
                            isPlanningLocked ? String(localized: "Unlock App") : String(localized: "Add another"),
                            systemImage: isPlanningLocked ? "lock.fill" : "plus"
                        )
                            .font(.caption.weight(.medium))
                            .foregroundStyle(showsBackdrop ? .white : Color.primary)
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
        .background { cardBackground(backdropDish) }
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .strokeBorder(
                    isTargeted
                        ? Color.accentColor
                        : accent.opacity(showsBackdrop ? 0 : (contrast == .increased ? 0.7 : 0.35)),
                    lineWidth: isTargeted ? 2.5 : (contrast == .increased ? 1.5 : 1)
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
        // A planned meal is a place you come back to, so where the platform
        // has windows it gets one of its own instead of a sheet over the plan.
        .detailPresentation(item: $selectedEntry, route: { .plannedMeal($0.uuid) }) { entry in
            EntryQuickActionsSheet(entry: entry)
                .dismissesOnOutsideClick()
        }
        .detailPresentation(item: $newDishToEdit, route: { .newRecipe($0.uuid) }) { dish in
            NavigationStack { DishEditorView(dish: dish, isNew: true) }
                .dismissesOnOutsideClick()
        }
        .detailPresentation(isPresented: $showingPaywall, route: .unlock) {
            PaywallView()
                .dismissesOnOutsideClick()
        }
    }

    private func showDetails(for entry: MealPlanEntrySnapshot) {
        selectedEntry = liveEntry(for: entry.uuid)
    }

    private func liveEntry(for uuid: UUID) -> MealPlanEntry? {
        try? context.fetch(
            FetchDescriptor<MealPlanEntry>(
                predicate: #Predicate<MealPlanEntry> { $0.uuid == uuid }
            )
        ).first
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
    private func cardBackground(_ dish: DishValueSnapshot?) -> some View {
        ZStack(alignment: .bottomTrailing) {
            Rectangle().fill(.background)
            Rectangle().fill(accent.opacity(colorScheme == .dark ? 0.28 : 0.16))
            backdropSymbol
                .offset(x: 22, y: 20)

            if let dish, let dishID = dish.persistentID {
                CachedDishPhoto(
                    dishID: dishID,
                    dishUUID: dish.uuid,
                    cacheKey: "dish-" + dish.uuid.uuidString + "-" + dish.modifiedAt.timeIntervalSinceReferenceDate.description,
                    maxPixelSize: 900
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(
                    LinearGradient(
                        colors: [.black.opacity(0.30), .black.opacity(0.42), .black.opacity(0.72)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .clipped()
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

    private func header(showsBackdrop: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbolName)
                .font(.caption)
            Text(title)
                .font(.caption.weight(.bold))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .foregroundStyle(showsBackdrop ? AnyShapeStyle(.white) : AnyShapeStyle(accent))
        .shadow(color: .black.opacity(showsBackdrop ? 0.5 : 0), radius: 2, y: 1)
    }

    // MARK: - Drag and drop

    /// The payload for dragging a planned meal. It carries the entry, so
    /// dropping it elsewhere on the plan moves this meal rather than planning a
    /// second helping of the same dish. `name` doubles as the plain-text
    /// representation when the drag ends up in another app.
    private func dragPayload(_ entry: MealPlanEntrySnapshot) -> DishReference {
        DishReference(
            dishUUID: entry.dish?.uuid ?? UUID(),
            name: entry.displayTitle,
            sourceEntryUUID: entry.uuid
        )
    }

    /// What travels under the finger or pointer. Worth spelling out: the
    /// automatic preview snapshots the row as it sits on the card, which on a
    /// photo card is white text over nothing.
    private func dragPreview(_ entry: MealPlanEntrySnapshot) -> some View {
        HStack(spacing: 8) {
            if let dish = entry.dish {
                DishThumbnail(
                    dishID: dish.persistentID,
                    dishUUID: dish.uuid,
                    cacheKey: "dish-" + dish.uuid.uuidString,
                    glyph: dish.glyph,
                    tint: DishGlyph.tint(forName: dish.name),
                    size: 28,
                    cornerRadius: 6
                )
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
        guard !isPlanningLocked else {
            showingPaywall = true
            return false
        }
        let accepted = MealPlanner.drop(
            ref, onto: date, mealKey: mealKey,
            household: appState.currentHousehold,
            memberName: appState.currentMemberName,
            context: context
        )
        if accepted {
            acceptedDrops += 1
            MealPlanTips.recordAcceptedDrop(ref)
        }
        return accepted
    }

    // MARK: - Context menu

    @ViewBuilder
    private func entryMenu(_ entry: MealPlanEntrySnapshot) -> some View {
        Button {
            repeatNextWeek(entry)
        } label: {
            Label(String(localized: "Repeat next week"), systemImage: "arrow.uturn.forward")
        }
        Button {
            showDetails(for: entry)
        } label: {
            Label(String(localized: "Edit / reschedule…"), systemImage: "slider.horizontal.3")
        }
        OpenInNewWindowButton(route: .plannedMeal(entry.uuid))
        Button(role: .destructive) {
            remove(entry)
        } label: {
            Label(String(localized: "Remove"), systemImage: "trash")
        }
    }

    private func showPlanningUI() {
        if isPlanningLocked {
            showingPaywall = true
        } else {
            showingPicker = true
        }
    }

    private func repeatNextWeek(_ entry: MealPlanEntrySnapshot) {
        let target = entry.date.adding(weeks: 1)
        guard purchaseManager.canPlan(on: target) else {
            showingPaywall = true
            return
        }
        guard let liveEntry = liveEntry(for: entry.uuid) else { return }
        MealPlanner.repeatEntry(liveEntry, weeksAhead: 1, memberName: appState.currentMemberName, context: context)
    }

    private func remove(_ entry: MealPlanEntrySnapshot) {
        guard let liveEntry = liveEntry(for: entry.uuid) else { return }
        let snapshot = MealPlanEntryUndoSnapshot(liveEntry)
        let name = entry.displayTitle
        try? withoutUndoRegistration(in: context) {
            context.delete(liveEntry)
            try context.save()
        }
        SharedStore.reloadWidgets()
        appState.offerUndo(String(localized: "Removed “\(name)”")) {
            try? withoutUndoRegistration(in: context) {
                try snapshot.restore(in: context)
                try context.save()
            }
            SharedStore.reloadWidgets()
        }
    }

    // MARK: - Entry row

    private func entryRow(_ entry: MealPlanEntrySnapshot, showsBackdrop: Bool) -> some View {
        let isEatingOut = entry.dish == nil && entry.isEatingOut

        return HStack(spacing: 8) {
            if isEatingOut {
                Image(systemName: "storefront")
                    .font(showsBackdrop ? .caption2 : .body)
                    .foregroundStyle(showsBackdrop ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(accent))
                    .frame(width: showsBackdrop ? 18 : 34)
            } else if !showsBackdrop {
                if let dish = entry.dish {
                    DishThumbnail(
                        dishID: dish.persistentID,
                        dishUUID: dish.uuid,
                        cacheKey: "dish-" + dish.uuid.uuidString,
                        glyph: dish.glyph,
                        tint: DishGlyph.tint(forName: dish.name),
                        size: 34,
                        cornerRadius: 8
                    )
                }
            } else {
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
                    .font(.subheadline.weight(showsBackdrop ? .semibold : .regular))
                    // This card's height follows its content, so an unbounded
                    // name would resize the day's whole band. The name shrinks
                    // into two lines instead of ending in an ellipsis.
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)
                    .strikethrough(entry.skipped)
                    .foregroundStyle(showsBackdrop ? AnyShapeStyle(.white) : AnyShapeStyle(entry.skipped ? Color.secondary : Color.primary))

                HStack(spacing: 6) {
                    if entry.routineUUID != nil {
                        Image(systemName: "repeat")
                            .help(String(localized: "Repeating meal"))
                            .accessibilityLabel(String(localized: "Repeating meal"))
                    }
                    if entry.servingsOverride != nil {
                        let servings = entry.servingsOverride ?? 1
                        Label(String(localized: "\(servings)"), systemImage: "person.2")
                            .labelStyle(.titleAndIcon)
                            .help(String(localized: "\(servings) servings"))
                            .accessibilityLabel(String(localized: "\(servings) servings"))
                    }
                    if entry.prepReminder {
                        Image(systemName: "bell")
                            .help(String(localized: "Prep reminder set"))
                            .accessibilityLabel(String(localized: "Prep reminder set"))
                    }
                    if let reaction = entry.reaction {
                        let reactionName = reaction == .down
                            ? String(localized: "Disliked")
                            : String(localized: "Liked")
                        Image(systemName: reaction.symbolName)
                            .foregroundStyle(showsBackdrop ? .white : (reaction == .down ? .red : .yellow))
                            .help(reactionName)
                            .accessibilityLabel(reactionName)
                    }
                    if entry.dish?.needsReview == true {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(showsBackdrop ? .white : .orange)
                            .help(String(localized: "Needs review"))
                            .accessibilityLabel(String(localized: "Needs review"))
                    }
                    // Reading the day's total is one thing; seeing which meal
                    // put it there is what makes tomorrow plannable.
                    if appState.showsNutritionEstimates,
                       let dish = entry.dish,
                       let estimate = nutritionSummary?.estimate(for: dish.uuid) {
                        MealNutritionCaption(estimate: estimate, unit: appState.energyUnit)
                    }
                }
                .font(.caption2)
                .foregroundStyle(showsBackdrop ? .white.opacity(0.9) : Color.secondary)
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)
        }
        .shadow(color: .black.opacity(showsBackdrop ? 0.45 : 0), radius: 2, y: 1)
    }
}

#Preview("Planned") {
    MealCard(
        date: .now,
        mealKey: PreviewData.mealType.key,
        title: PreviewData.mealType.name,
        symbolName: PreviewData.mealType.symbolName,
        entries: PreviewData.entries(on: .now, mealKey: PreviewData.mealType.key).map(MealPlanEntrySnapshot.init)
    )
    .frame(width: 220)
    .padding()
    .environment(AppState.preview)
    .environment(PurchaseManager.shared)
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
    .environment(PurchaseManager.shared)
    .modelContainer(PreviewData.container)
}
