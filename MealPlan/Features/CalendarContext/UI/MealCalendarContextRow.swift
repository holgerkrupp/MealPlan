import SwiftUI

/// The one line of calendar context inside a day of the plan.
///
/// Deliberately quiet: small, secondary, at most two chips, and never larger
/// than the meals themselves. Tapping it opens the detail — the week overview
/// stays compact.
@MainActor
struct MealCalendarContextRow: View {
    let day: Date
    let meals: [DayMeal]

    @Environment(CalendarContextStore.self) private var store: CalendarContextStore?
    @State private var showingDetail = false

    private static let maxChips = 2

    private var contexts: [MealPlanningContext] {
        store?.contexts(for: day, meals: meals) ?? []
    }

    var body: some View {
        let dayContexts = contexts
        if !dayContexts.isEmpty {
            Button {
                showingDetail = true
            } label: {
                HStack(spacing: 8) {
                    ForEach(dayContexts.prefix(Self.maxChips)) { context in
                        chip(context, showsMealName: dayContexts.count > 1)
                    }
                    if dayContexts.count > Self.maxChips {
                        Text("+\(dayContexts.count - Self.maxChips)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(spokenSummary(dayContexts))
            .accessibilityHint(String(localized: "Shows the schedule around each meal."))
            .accessibilityAddTraits(.isButton)
            .sheet(isPresented: $showingDetail) {
                MealCalendarContextSheet(day: day, contexts: dayContexts)
            }
        }
    }

    private func chip(_ context: MealPlanningContext, showsMealName: Bool) -> some View {
        // Busyness is carried by the symbol and the words, never by colour
        // alone.
        HStack(spacing: 4) {
            Image(systemName: context.symbolName)
                .font(.caption2)
            Text(showsMealName ? "\(context.mealName): \(context.summary)" : context.summary)
                .font(.caption)
                .lineLimit(1)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.quaternary.opacity(0.5), in: Capsule())
    }

    private func spokenSummary(_ contexts: [MealPlanningContext]) -> String {
        let parts = contexts.map { "\($0.mealName): \($0.summary)" }.joined(separator: ", ")
        return String(localized: "Calendar context: \(parts).")
    }
}

/// The progressive-disclosure detail behind a context chip. Shows exactly as
/// much as the chosen privacy level allows — never more.
@MainActor
struct MealCalendarContextSheet: View {
    let day: Date
    let contexts: [MealPlanningContext]

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(contexts) { context in
                    Section {
                        ForEach(context.detailLines) { line in
                            row(line)
                        }
                        ForEach(context.householdAvailability) { person in
                            Label(person.localizedSummary, systemImage: "person")
                                .font(.subheadline)
                                .accessibilityLabel(person.localizedSummary)
                        }
                        if context.hasStaggeredAvailability {
                            Label(
                                String(localized: "People are free at different times."),
                                systemImage: "arrow.left.and.right"
                            )
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        }
                    } header: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(context.mealName)
                            Text(context.summary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textCase(nil)
                        }
                    }
                }

                Section {
                    Text("From the calendars you chose for meal planning. MealPlan never changes your calendar.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(day.formatted(.dateTime.weekday(.wide).day().month()))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Done")) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func row(_ line: MealContextDetailLine) -> some View {
        HStack(spacing: 10) {
            Image(systemName: line.isAllDay ? "calendar" : "clock")
                .foregroundStyle(.secondary)
                .font(.caption)
            VStack(alignment: .leading, spacing: 2) {
                if let title = line.title, !title.isEmpty {
                    Text(title)
                        .font(.subheadline)
                }
                Text(line.timeText)
                    .font(line.title == nil ? .subheadline : .caption)
                    .foregroundStyle(line.title == nil ? .primary : .secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(line.spokenText)
    }
}
