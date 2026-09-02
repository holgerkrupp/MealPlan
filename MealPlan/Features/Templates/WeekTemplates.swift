import SwiftUI
import SwiftData

/// Save / apply reusable week patterns.
enum TemplateEngine {

    static func weekdayIndex(of date: Date) -> Int {
        // mondayCalendar weekday: 1 = Sunday … 7 = Saturday. Monday should be 0.
        let weekday = Date.mondayCalendar.component(.weekday, from: date)
        return (weekday + 5) % 7
    }

    struct PlannedSlot: Equatable {
        var date: Date
        var mealKey: String
        var servingsOverride: Int?
    }

    /// Pure expansion of a template onto a concrete week (no persistence).
    static func expand(_ template: WeekTemplate, weekStart: Date) -> [PlannedSlot] {
        let start = weekStart.startOfWeek()
        return template.sortedEntries.map {
            PlannedSlot(date: start.adding(days: $0.weekday), mealKey: $0.mealKey, servingsOverride: $0.servingsOverride)
        }
    }

    @MainActor
    static func saveTemplate(
        name: String,
        weekStart: Date,
        household: Household?,
        createdBy: String,
        context: ModelContext
    ) {
        let start = weekStart.startOfWeek()
        let end = start.adding(weeks: 1)
        let entries = (try? context.fetch(FetchDescriptor<MealPlanEntry>(
            predicate: #Predicate { $0.date >= start && $0.date < end && $0.skipped == false }
        ))) ?? []

        let template = WeekTemplate(name: name)
        template.household = household
        template.createdByName = createdBy
        context.insert(template)

        for entry in entries {
            guard let dish = entry.dish else { continue }
            let te = WeekTemplateEntry(weekday: weekdayIndex(of: entry.date), mealKey: entry.mealKey, dish: dish)
            te.servingsOverride = entry.servingsOverride
            te.sortIndex = entry.sortIndex
            te.template = template
            context.insert(te)
        }
        try? context.save()
    }

    @MainActor
    static func apply(
        _ template: WeekTemplate,
        toWeekContaining date: Date,
        replaceExisting: Bool,
        household: Household?,
        memberName: String,
        context: ModelContext
    ) {
        let start = date.startOfWeek()
        if replaceExisting {
            let end = start.adding(weeks: 1)
            let existing = (try? context.fetch(FetchDescriptor<MealPlanEntry>(
                predicate: #Predicate { $0.date >= start && $0.date < end }
            ))) ?? []
            existing.forEach(context.delete)
        }
        for te in template.sortedEntries {
            guard let dish = te.dish else { continue }
            MealPlanner.plan(
                dish: dish,
                on: start.adding(days: te.weekday),
                mealKey: te.mealKey,
                servings: te.servingsOverride,
                household: household,
                memberName: memberName,
                context: context
            )
        }
        try? context.save()
    }
}

// MARK: - Save sheet

@MainActor
struct SaveTemplateSheet: View {
    let weekStart: Date

    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""

    var body: some View {
        NavigationStack {
            Form {
                Section(String(localized: "Template name")) {
                    TextField(String(localized: "e.g. Standard week"), text: $name)
                }
                Section {
                    LabeledContent(
                        String(localized: "From week of"),
                        value: weekStart.formatted(date: .abbreviated, time: .omitted)
                    )
                }
            }
            .navigationTitle(String(localized: "Save as template"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Save")) {
                        TemplateEngine.saveTemplate(
                            name: name.isEmpty ? String(localized: "Week template") : name,
                            weekStart: weekStart,
                            household: appState.currentHousehold,
                            createdBy: appState.currentMemberName,
                            context: context
                        )
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - Apply sheet

@MainActor
struct ApplyTemplateSheet: View {
    let targetWeekStart: Date

    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \WeekTemplate.name) private var templates: [WeekTemplate]

    @State private var replaceExisting = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle(String(localized: "Replace what’s already planned"), isOn: $replaceExisting)
                }
                if templates.isEmpty {
                    ContentUnavailableView(
                        String(localized: "No templates yet"),
                        systemImage: "square.on.square",
                        description: Text("Save a week as a template first.")
                    )
                } else {
                    Section(String(localized: "Apply to week of \(targetWeekStart.formatted(date: .abbreviated, time: .omitted))")) {
                        ForEach(templates) { template in
                            Button {
                                TemplateEngine.apply(
                                    template, toWeekContaining: targetWeekStart,
                                    replaceExisting: replaceExisting,
                                    household: appState.currentHousehold,
                                    memberName: appState.currentMemberName,
                                    context: context
                                )
                                dismiss()
                            } label: {
                                VStack(alignment: .leading) {
                                    Text(template.name)
                                    Text(String(localized: "\(template.sortedEntries.count) meals"))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .onDelete { offsets in
                            offsets.map { templates[$0] }.forEach(context.delete)
                            try? context.save()
                        }
                    }
                }
            }
            .navigationTitle(String(localized: "Use a template"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel")) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

#Preview("Save template") {
    SaveTemplateSheet(weekStart: Date.now.startOfWeek())
        .environment(AppState.preview)
        .modelContainer(PreviewData.container)
}

#Preview("Apply template") {
    ApplyTemplateSheet(targetWeekStart: Date.now.startOfWeek())
        .environment(AppState.preview)
        .modelContainer(PreviewData.container)
}
