import SwiftUI
import SwiftData

/// The compact week picker above the plan: one button per day of the visible
/// week, with arrows to step a week back or forward. A progress ring around each
/// day number fills as that day's meals get planned — a complete ring (and a
/// bold number) means every meal is covered — so a glance shows how full the
/// week is.
///
/// The plan's own sections are always Monday-based (that is what "week 36"
/// means), but this strip follows the user's locale, so it starts on Sunday
/// where that is the convention.
///
/// The strip is also the plan's long-distance drop target: a meal dragged onto
/// a day moves there, and holding a drag over an arrow pages the strip, so a
/// meal can be moved into a week that isn't on screen. Scrolling the plan
/// itself under a drag only works on iOS, and not at all on the Mac.
@MainActor
struct WeekStripView: View {
    /// First day of the week being shown; the arrows move it.
    @Binding var weekStart: Date
    let selectedDate: Date
    /// `dayID`s of the day cards currently on screen in the plan below.
    let visibleDayIDs: Set<String>
    /// Handles a meal dragged onto one of the day cells. Returns false when
    /// there is nothing to do, so the drag animates back.
    var onDropDish: ([DishReference], Date) -> Bool = { _, _ in false }
    var onSelect: (Date) -> Void
    /// Whether the "Jump to date" popover is open. It hangs off the month
    /// title; a binding so the menu bar's ⇧⌘T can open it too.
    @Binding var isPickingDate: Bool
    var onJumpToDate: (Date) -> Void

    /// This week's planned meals, and the household's meals. Both are handed
    /// down from the calendar rather than queried here: a `@Query` whose
    /// predicate follows `weekStart` needed the whole strip to be rebuilt —
    /// and refetched — every time the plan scrolled across a week boundary.
    let entries: [MealPlanEntry]
    let mealTypes: [MealType]

    /// The `dayID` a drag is currently hovering over, if any.
    @State private var targetedDayID: String?
    /// Pages the strip while a drag rests on one of the arrows.
    @State private var pagingTask: Task<Void, Never>?
    @State private var jumpDate = Date.now

    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Space between two day cells; the pill's geometry is derived from it.
    private static let cellSpacing: CGFloat = 4

    init(
        weekStart: Binding<Date>,
        selectedDate: Date,
        visibleDayIDs: Set<String>,
        entries: [MealPlanEntry],
        mealTypes: [MealType],
        onDropDish: @escaping ([DishReference], Date) -> Bool = { _, _ in false },
        isPickingDate: Binding<Bool> = .constant(false),
        onJumpToDate: @escaping (Date) -> Void = { _ in },
        onSelect: @escaping (Date) -> Void
    ) {
        _weekStart = weekStart
        self.selectedDate = selectedDate
        self.visibleDayIDs = visibleDayIDs
        self.entries = entries
        self.mealTypes = mealTypes
        self.onDropDish = onDropDish
        _isPickingDate = isPickingDate
        self.onJumpToDate = onJumpToDate
        self.onSelect = onSelect
    }

    /// One cell's worth of resolved state. Built for all seven days in a single
    /// pass: the strip redraws on every visibility change the plan reports, so
    /// each day re-filtering the week's entries for its own ring was seven
    /// passes over the array per scrolled frame.
    private struct DayCellModel: Identifiable {
        /// Position in the week, and the cell's identity. Deliberately not the
        /// date: a cell that keeps its identity across a week change updates
        /// its number and ring in place, rather than seven cells being torn
        /// out and seven new ones animated in as the plan scrolls past a week.
        let id: Int
        let date: Date
        let dayID: String
        /// How much of the day is planned, 0…1 — the share of the household's
        /// meals that have at least one un-skipped entry.
        let fraction: Double
    }

    private var dayCells: [DayCellModel] {
        var planned: [String: Set<String>] = [:]
        for entry in entries where !entry.skipped {
            planned[entry.date.dayID, default: []].insert(entry.mealKey)
        }
        let keys = Set(mealTypes.map(\.key))
        return (0..<7).map { offset in
            let day = weekStart.adding(days: offset)
            let dayID = day.dayID
            let covered = planned[dayID]?.intersection(keys).count ?? 0
            return DayCellModel(
                id: offset,
                date: day,
                dayID: dayID,
                fraction: keys.isEmpty ? 0 : Double(covered) / Double(keys.count)
            )
        }
    }

    /// Month (and year, when the week straddles two) for the shown week.
    private var title: String {
        let midWeek = weekStart.adding(days: 3)
        let last = weekStart.adding(days: 6)
        let sameMonth = Calendar.current.isDate(weekStart, equalTo: last, toGranularity: .month)
        return sameMonth
            ? midWeek.formatted(.dateTime.month(.wide).year())
            : "\(weekStart.formatted(.dateTime.month(.abbreviated))) – \(last.formatted(.dateTime.month(.abbreviated).year()))"
    }

    var body: some View {
        let cells = dayCells
        let span = visibleSpan(in: cells)

        return VStack(spacing: 8) {
            HStack {
                stepButton(weeks: -1, symbol: "chevron.left", label: String(localized: "Previous week"))
                Spacer(minLength: 0)
                titleButton
                Spacer(minLength: 0)
                stepButton(weeks: 1, symbol: "chevron.right", label: String(localized: "Next week"))
            }

            HStack(spacing: Self.cellSpacing) {
                ForEach(cells) { cell in
                    dayCell(cell)
                }
            }
            .background(alignment: .leading) { visiblePill(span: span) }
        }
        .animation(reduceMotion ? nil : .snappy, value: weekStart)
    }

    /// The span of this week's days that the plan below is currently showing,
    /// as indices into `cells`. Nil when the strip is parked on another week.
    private func visibleSpan(in cells: [DayCellModel]) -> ClosedRange<Int>? {
        let indices = cells.indices.filter { visibleDayIDs.contains(cells[$0].dayID) }
        guard let first = indices.first, let last = indices.last else { return nil }
        return first...last
    }

    /// A Liquid Glass pill laid over the days that are on screen in the plan,
    /// so the strip shows at a glance where the scroll position is.
    @ViewBuilder
    private func visiblePill(span: ClosedRange<Int>?) -> some View {
        GeometryReader { proxy in
            if let span {
                let spacing = Self.cellSpacing
                let cell = (proxy.size.width - spacing * 6) / 7
                let width = CGFloat(span.count) * cell + CGFloat(span.count - 1) * spacing
                let x = CGFloat(span.lowerBound) * (cell + spacing)

                Color.clear
                    .glassEffect(.regular, in: .capsule)
                    .frame(width: width + 8, height: proxy.size.height + 10)
                    .offset(x: x - 4, y: -5)
            }
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: span)
        .allowsHitTesting(false)
    }

    /// The month title doubles as the way to jump to any date.
    private var titleButton: some View {
        Button {
            isPickingDate = true
        } label: {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .contentTransition(reduceMotion ? .identity : .numericText())
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(String(localized: "Jump to date…"))
        .accessibilityHint(String(localized: "Jump to date"))
        // Opens downward, over the plan: the title sits right under the
        // navigation bar, so a popover above it gets squeezed to a sliver.
        .popover(isPresented: $isPickingDate, arrowEdge: .top) {
            datePicker
                .presentationCompactAdaptation(.popover)
        }
        .onChange(of: isPickingDate) { _, picking in
            if picking { jumpDate = selectedDate }
        }
    }

    /// Where the plan jumps to. A small transient chooser, so it stays a
    /// popover rather than becoming a window of its own.
    private var datePicker: some View {
        VStack(alignment: .trailing, spacing: 12) {
            DatePicker(
                String(localized: "Jump to date"),
                selection: $jumpDate,
                displayedComponents: .date
            )
            .datePickerStyle(.graphical)
            .labelsHidden()

            HStack {
                Button(String(localized: "Cancel")) { isPickingDate = false }
                Button(String(localized: "Go")) {
                    isPickingDate = false
                    onJumpToDate(jumpDate)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(minWidth: 300)
    }

    private func stepButton(weeks: Int, symbol: String, label: String) -> some View {
        Button {
            weekStart = weekStart.adding(weeks: weeks)
        } label: {
            Image(systemName: symbol)
                .font(.subheadline.weight(.semibold))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // An arrow never takes the meal itself, it only turns the page, so a
        // drag can reach a week that is off screen.
        .dropDestination(for: DishReference.self) { _, _ in
            false
        } isTargeted: { targeted in
            pageWeek(by: weeks, whileTargeted: targeted)
        }
        .accessibilityLabel(label)
    }

    /// Steps the strip one week while a drag rests on an arrow. Deliberately
    /// one step per hover: the strip is rebuilt on the new week, and if the
    /// drag is still on the arrow it simply asks again.
    private func pageWeek(by weeks: Int, whileTargeted targeted: Bool) {
        pagingTask?.cancel()
        guard targeted else {
            pagingTask = nil
            return
        }
        pagingTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            weekStart = weekStart.adding(weeks: weeks)
        }
    }

    private func dayCell(_ cell: DayCellModel) -> some View {
        let day = cell.date
        let isSelected = day.isSameDay(as: selectedDate)
        let isToday = day.isSameDay(as: .now)
        let fraction = cell.fraction
        let fullyPlanned = fraction >= 1
        let isDropTarget = targetedDayID == cell.dayID

        return Button {
            onSelect(day)
        } label: {
            VStack(spacing: 4) {
                Text(day.formatted(.dateTime.weekday(.narrow)))
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                ZStack {
                    // Selection fill sits inside the ring so both stay legible.
                    if isSelected { Circle().fill(.tint).padding(2) }

                    Circle()
                        .stroke(
                            isSelected
                                ? AnyShapeStyle(.white.opacity(contrast == .increased ? 0.5 : 0.3))
                                : AnyShapeStyle(contrast == .increased ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.quaternary)),
                            lineWidth: 3
                        )
                    Circle()
                        .trim(from: 0, to: fraction)
                        .stroke(
                            isSelected ? Color.white : Color.accentColor,
                            style: StrokeStyle(lineWidth: 3, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                        .animation(.snappy, value: fraction)

                    Text(day.formatted(.dateTime.day()))
                        .font(.subheadline.weight(fullyPlanned ? .bold : .regular))
                        .monospacedDigit()
                        .foregroundStyle(numberStyle(isSelected: isSelected, isToday: isToday))
                }
                .frame(width: 32, height: 32)
                // Today is an outer ring, so it still reads as today when
                // another day carries the filled selection.
                .overlay {
                    if isToday && !isSelected {
                        Circle()
                            .strokeBorder(Color.accentColor, lineWidth: 2)
                            .padding(-2)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background {
            if isDropTarget {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.accentColor.opacity(0.18))
            }
        }
        .contentShape(Rectangle())
        // Dropping here keeps the meal in its own meal type and only changes
        // the day — the strip has no meals to aim at.
        .dropDestination(for: DishReference.self) { references, _ in
            onDropDish(references, day)
        } isTargeted: { targeted in
            setTargeted(targeted, for: day)
        }
        .animation(.snappy(duration: 0.15), value: isDropTarget)
        .accessibilityLabel(day.formatted(.dateTime.weekday(.wide).day().month(.wide)))
        .accessibilityValue(
            fullyPlanned
                ? String(localized: "All meals planned")
                : (fraction > 0 ? String(localized: "Partly planned") : String(localized: "Nothing planned"))
        )
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    /// Tracks the hovered day. The "left" callback of the day being dragged
    /// away from can arrive after the "entered" callback of the next one, so a
    /// day only ever clears its own highlight.
    private func setTargeted(_ targeted: Bool, for day: Date) {
        if targeted {
            targetedDayID = day.dayID
        } else if targetedDayID == day.dayID {
            targetedDayID = nil
        }
    }

    private func numberStyle(isSelected: Bool, isToday: Bool) -> AnyShapeStyle {
        if isSelected { return AnyShapeStyle(.white) }
        if isToday { return AnyShapeStyle(Color.accentColor) }
        return AnyShapeStyle(Color.primary)
    }
}

#Preview {
    @Previewable @State var weekStart = Date.now.startOfWeek(calendar: .current)
    WeekStripView(
        weekStart: $weekStart,
        selectedDate: .now,
        visibleDayIDs: [Date.now.dayID],
        entries: [],
        mealTypes: [],
        onSelect: { _ in }
    )
    .padding(.vertical)
    .modelContainer(PreviewData.container)
}
