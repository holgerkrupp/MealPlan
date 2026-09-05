import SwiftUI

/// One meal slot on the plan stripe — built from a `MealType` in the app, or
/// from the Share Extension's plain meal tuples.
struct MealStripSlot: Identifiable, Hashable {
    let key: String
    let name: String
    let symbolName: String
    /// Whether a day needs this slot filled to read as fully planned. False for
    /// the extras row: a day nobody planned an extra on is not half-empty.
    var countsTowardCompletion: Bool = true
    var id: String { key }
}

/// The shared drawing and scroll behaviour behind the "plan stripe": a
/// horizontally scrolling, lazily-growing band of upcoming days, each with a
/// progress ring around the date and one small square per meal, so a glance
/// shows which days are already full.
///
/// It owns no data and causes no side effects. The caller supplies the slots,
/// a `plannedKeys(day)` lookup and an `onSelect` closure: the app wraps it to
/// plan or reschedule a dish on tap, the Share Extension wraps it as a plain
/// day + meal picker.
@MainActor
struct MealPlannerStripCore: View {
    let slots: [MealStripSlot]
    /// Meal keys that already have an un-skipped entry on the given day.
    let plannedKeys: (Date) -> Set<String>
    /// When set, the matching square is badged as "this is the item being moved".
    var entrySlot: (day: Date, key: String)?
    @Binding var selectedDate: Date
    @Binding var selectedMealKey: String
    /// A square was tapped. The caller updates its state / plans / reschedules.
    var onSelect: (_ day: Date, _ key: String) -> Void
    /// Locked dates stay visible, but their slots lead to an unlock action.
    var isDateLocked: (Date) -> Bool = { _ in false }
    var onSelectLockedDate: (Date) -> Void = { _ in }
    var isDisabled: Bool = false
    /// Accessibility hint spoken for each square ("Plans this dish here", …).
    var selectHint: String = ""

    private static let pastDays = 14
    @State private var futureDays = 45
    @State private var tapTick = 0
    /// Stops the auto-recentre once the user starts tapping.
    @State private var didUserTap = false

    private let today = Date.now.startOfDay
    private let squareSize: CGFloat = 40
    private let columnWidth: CGFloat = 48

    private var days: [Date] {
        (-Self.pastDays...futureDays).map { today.adding(days: $0) }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 6) {
                    ForEach(days, id: \.self) { day in
                        dayColumn(day)
                            .id(day.dayID)
                    }
                    Color.clear
                        .frame(width: 1)
                        .onAppear { futureDays += 21 }
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 6)
                .scrollTargetLayout()
            }
            .onAppear {
                proxy.scrollTo(selectedDate.dayID, anchor: .center)
            }
            // Re-centre when the date is set from outside (the sheet finishes
            // wiring up its state, or a jump elsewhere) — but not once the user
            // has started tapping slots here.
            .onChange(of: selectedDate) { _, newValue in
                guard !didUserTap else { return }
                withAnimation(.snappy) { proxy.scrollTo(newValue.dayID, anchor: .center) }
            }
        }
        .frame(height: columnHeight)
        .sensoryFeedback(.success, trigger: tapTick)
    }

    private var columnHeight: CGFloat {
        // Header (30) + spacing + one square per meal.
        30 + 8 + CGFloat(max(slots.count, 1)) * (squareSize + 6) + 12
    }

    // MARK: - Day column

    @ViewBuilder
    private func dayColumn(_ day: Date) -> some View {
        let planned = plannedKeys(day)
        let counted = slots.filter(\.countsTowardCompletion)
        let fraction = counted.isEmpty
            ? 0
            : Double(counted.filter { planned.contains($0.key) }.count) / Double(counted.count)

        VStack(spacing: 8) {
            dayHeader(day, fraction: fraction)

            VStack(spacing: 6) {
                ForEach(slots) { slot in
                    mealSquare(day: day, slot: slot, isFilled: planned.contains(slot.key))
                }
            }
        }
        .frame(width: columnWidth)
        .padding(.vertical, 4)
        .background {
            if day.isSameDay(as: selectedDate) {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.accentColor.opacity(0.10))
            }
        }
    }

    private func dayHeader(_ day: Date, fraction: Double) -> some View {
        let isToday = day.isSameDay(as: .now)
        let isSelected = day.isSameDay(as: selectedDate)

        return VStack(spacing: 2) {
            Text(day.formatted(.dateTime.weekday(.narrow)))
                .font(.caption2)
                .foregroundStyle(.secondary)

            ZStack {
                Circle()
                    .stroke(.quaternary, lineWidth: 3)
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.snappy, value: fraction)
                if isSelected {
                    Circle().fill(.tint).padding(3)
                }
                Text(day.formatted(.dateTime.day()))
                    .font(.caption.weight(fraction >= 1 ? .bold : .regular))
                    .monospacedDigit()
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            }
            .frame(width: 30, height: 30)
            .overlay {
                if isToday && !isSelected {
                    Circle().strokeBorder(Color.accentColor, lineWidth: 1.5).padding(-2)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(day.formatted(.dateTime.weekday(.wide).day().month(.wide)))
        .accessibilityValue(
            fraction >= 1
                ? String(localized: "All meals planned")
                : (fraction > 0 ? String(localized: "Partly planned") : String(localized: "Nothing planned"))
        )
    }

    // MARK: - Meal square

    private func mealSquare(day: Date, slot: MealStripSlot, isFilled: Bool) -> some View {
        let accent = Self.accent(for: slot.key)
        let isLocked = isDateLocked(day)
        let isCurrentSlot = day.isSameDay(as: selectedDate) && slot.key == selectedMealKey
        let isEntrySlot = entrySlot.map { $0.day.isSameDay(as: day) && $0.key == slot.key } ?? false

        return Button {
            didUserTap = true
            if isLocked {
                onSelectLockedDate(day)
            } else {
                tapTick += 1
                onSelect(day, slot.key)
            }
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isFilled ? accent.opacity(0.22) : Color.clear)
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        isCurrentSlot ? Color.accentColor : accent.opacity(isFilled ? 0.5 : 0.35),
                        style: StrokeStyle(lineWidth: isCurrentSlot ? 2 : 1, dash: isFilled ? [] : [3, 2])
                    )

                Image(systemName: slot.symbolName)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(isFilled ? AnyShapeStyle(accent) : AnyShapeStyle(.secondary))
                    .opacity(isFilled ? 0.9 : 0.55)

                if isLocked {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(3)
                        .background(.thinMaterial, in: Circle())
                }

                if isFilled {
                    Image(systemName: isEntrySlot ? "location.fill" : "checkmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(2)
                        .background(Circle().fill(isEntrySlot ? Color.accentColor : accent))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .padding(3)
                }
            }
            .frame(width: squareSize, height: squareSize)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .accessibilityLabel("\(slot.name), \(day.formatted(.dateTime.weekday(.wide).day().month()))")
        .accessibilityValue(isFilled ? String(localized: "Planned") : String(localized: "Empty"))
        .accessibilityHint(
            isLocked
                ? String(localized: "Unlock MealPlan to plan this far ahead")
                : selectHint
        )
    }

    // MARK: - Colour

    /// Stable accent colour derived from a meal key (djb2). Mirrors `MealCard`
    /// so a meal keeps the same colour on the stripe and on the calendar.
    private static let palette: [Color] = [
        .orange, .blue, .green, .purple, .pink, .teal, .indigo, .brown, .mint, .red,
    ]

    static func accent(for key: String) -> Color {
        var hash: UInt64 = 5381
        for byte in key.utf8 { hash = (hash &* 33) ^ UInt64(byte) }
        return palette[Int(hash % UInt64(palette.count))]
    }
}
