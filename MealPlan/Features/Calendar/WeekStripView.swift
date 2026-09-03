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
@MainActor
struct WeekStripView: View {
    /// First day of the week being shown; the arrows move it.
    @Binding var weekStart: Date
    let selectedDate: Date
    /// `dayID`s of the day cards currently on screen in the plan below.
    let visibleDayIDs: Set<String>
    var onSelect: (Date) -> Void

    @Query private var entries: [MealPlanEntry]
    @Query(sort: [SortDescriptor(\MealType.sortOrder), SortDescriptor(\MealType.name)])
    private var mealTypes: [MealType]

    /// Space between two day cells; the pill's geometry is derived from it.
    private static let cellSpacing: CGFloat = 4

    init(
        weekStart: Binding<Date>,
        selectedDate: Date,
        visibleDayIDs: Set<String>,
        onSelect: @escaping (Date) -> Void
    ) {
        _weekStart = weekStart
        self.selectedDate = selectedDate
        self.visibleDayIDs = visibleDayIDs
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

    /// How much of `day` is planned, 0…1 — the share of the household's meals
    /// that have at least one un-skipped entry. Drives the ring around the
    /// day number.
    private func mealFraction(on day: Date) -> Double {
        guard !mealTypes.isEmpty else { return 0 }
        let planned = Set(
            entries
                .filter { $0.date.isSameDay(as: day) && !$0.skipped }
                .map(\.mealKey)
        )
        let covered = mealTypes.filter { planned.contains($0.key) }.count
        return Double(covered) / Double(mealTypes.count)
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
        .accessibilityLabel(label)
    }

    private func dayCell(_ day: Date) -> some View {
        let isSelected = day.isSameDay(as: selectedDate)
        let isToday = day.isSameDay(as: .now)
        let fraction = mealFraction(on: day)
        let fullyPlanned = fraction >= 1

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
                            isSelected ? AnyShapeStyle(.white.opacity(0.3)) : AnyShapeStyle(.quaternary),
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
        .accessibilityLabel(day.formatted(.dateTime.weekday(.wide).day().month(.wide)))
        .accessibilityValue(
            fullyPlanned
                ? String(localized: "All meals planned")
                : (fraction > 0 ? String(localized: "Partly planned") : String(localized: "Nothing planned"))
        )
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
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
