import SwiftUI
import SwiftData

/// The compact week picker above the plan: one button per day of the visible
/// week, with arrows to step a week back or forward. A day whose number is bold
/// (and carries a dot) already has meals planned, so a glance shows how full
/// the week is.
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

    @Query private var entries: [MealPlanEntry]

    /// The `dayID` a drag is currently hovering over, if any.
    @State private var targetedDayID: String?
    /// Pages the strip while a drag rests on one of the arrows.
    @State private var pagingTask: Task<Void, Never>?

    /// Space between two day cells; the pill's geometry is derived from it.
    private static let cellSpacing: CGFloat = 4

    init(
        weekStart: Binding<Date>,
        selectedDate: Date,
        visibleDayIDs: Set<String>,
        onDropDish: @escaping ([DishReference], Date) -> Bool = { _, _ in false },
        onSelect: @escaping (Date) -> Void
    ) {
        _weekStart = weekStart
        self.selectedDate = selectedDate
        self.visibleDayIDs = visibleDayIDs
        self.onDropDish = onDropDish
        self.onSelect = onSelect
        let start = weekStart.wrappedValue
        let end = start.adding(weeks: 1)
        _entries = Query(
            filter: #Predicate<MealPlanEntry> { $0.date >= start && $0.date < end },
            sort: \MealPlanEntry.date
        )
    }

    private var days: [Date] {
        (0..<7).map { weekStart.adding(days: $0) }
    }

    /// The days of this week that already have at least one dish planned.
    private var plannedDayIDs: Set<String> {
        Set(entries.map(\.date.dayID))
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
        VStack(spacing: 8) {
            HStack {
                stepButton(weeks: -1, symbol: "chevron.left", label: String(localized: "Previous week"))
                Spacer(minLength: 0)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .contentTransition(.numericText())
                Spacer(minLength: 0)
                stepButton(weeks: 1, symbol: "chevron.right", label: String(localized: "Next week"))
            }

            HStack(spacing: Self.cellSpacing) {
                ForEach(days, id: \.self) { day in
                    dayCell(day)
                }
            }
            .background(alignment: .leading) { visiblePill }
        }
        .animation(.snappy, value: weekStart)
    }

    /// The span of this week's days that the plan below is currently showing,
    /// as indices into `days`. Nil when the strip is parked on another week.
    private var visibleSpan: ClosedRange<Int>? {
        let indices = days.indices.filter { visibleDayIDs.contains(days[$0].dayID) }
        guard let first = indices.first, let last = indices.last else { return nil }
        return first...last
    }

    /// A Liquid Glass pill laid over the days that are on screen in the plan,
    /// so the strip shows at a glance where the scroll position is.
    @ViewBuilder
    private var visiblePill: some View {
        GeometryReader { proxy in
            if let span = visibleSpan {
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
        .animation(.smooth(duration: 0.25), value: visibleSpan)
        .allowsHitTesting(false)
    }

    private func stepButton(weeks: Int, symbol: String, label: String) -> some View {
        Button {
            weekStart = weekStart.adding(weeks: weeks)
        } label: {
            Image(systemName: symbol)
                .font(.subheadline.weight(.semibold))
                .frame(width: 34, height: 34)
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

    private func dayCell(_ day: Date) -> some View {
        let isSelected = day.isSameDay(as: selectedDate)
        let isToday = day.isSameDay(as: .now)
        let hasMeals = plannedDayIDs.contains(day.dayID)
        let isDropTarget = targetedDayID == day.dayID

        return Button {
            onSelect(day)
        } label: {
            VStack(spacing: 3) {
                Text(day.formatted(.dateTime.weekday(.narrow)))
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Text(day.formatted(.dateTime.day()))
                    .font(.subheadline.weight(hasMeals ? .bold : .regular))
                    .monospacedDigit()
                    .foregroundStyle(numberStyle(isSelected: isSelected, isToday: isToday))
                    .frame(width: 32, height: 32)
                    .background {
                        if isSelected { Circle().fill(.tint) }
                    }
                    // Today is a ring, so it still reads as today when another
                    // day carries the filled selection.
                    .overlay {
                        if isToday {
                            Circle()
                                .strokeBorder(Color.accentColor, lineWidth: 2)
                                .padding(-2)
                        }
                    }

                Circle()
                    .fill(hasMeals ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear))
                    .frame(width: 4, height: 4)
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
        .accessibilityValue(hasMeals ? String(localized: "Meals planned") : String(localized: "Nothing planned"))
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
        onSelect: { _ in }
    )
    .padding(.vertical)
    .modelContainer(PreviewData.container)
}
