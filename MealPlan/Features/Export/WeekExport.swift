import SwiftUI
import SwiftData

struct WeekExportData {
    struct Slot: Identifiable { var id = UUID(); var name: String; var dishes: [String] }
    struct Day: Identifiable { var id = UUID(); var title: String; var slots: [Slot] }
    var title: String
    var days: [Day]
}

enum WeekExport {

    @MainActor
    static func data(forWeekContaining date: Date, householdName: String, context: ModelContext) -> WeekExportData {
        let start = date.startOfWeek()
        let end = start.adding(weeks: 1)
        let entries = (try? context.fetch(FetchDescriptor<MealPlanEntry>(
            predicate: #Predicate { $0.date >= start && $0.date < end && $0.skipped == false }
        ))) ?? []

        let mealTypes = (try? context.fetch(FetchDescriptor<MealType>(
            sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.name)]
        ))) ?? []

        // Configured meals, plus any legacy meal key still present on an entry.
        var meals: [(key: String, name: String)] = mealTypes.map { ($0.key, $0.name) }
        let known = Set(meals.map(\.key))
        for key in Set(entries.map(\.mealKey)).subtracting(known).subtracting([""]).sorted() {
            meals.append((key, MealType.legacyName(for: key)))
        }

        let df = DateFormatter()
        df.setLocalizedDateFormatFromTemplate("EEEEdMMM")

        let days: [WeekExportData.Day] = (0..<7).map { offset in
            let day = start.adding(days: offset)
            let slots: [WeekExportData.Slot] = meals.map { meal in
                let names = entries
                    .filter { $0.date.isSameDay(as: day) && $0.mealKey == meal.key }
                    .sorted { $0.sortIndex < $1.sortIndex }
                    .map(\.displayTitle)
                return WeekExportData.Slot(name: meal.name, dishes: names)
            }
            return WeekExportData.Day(title: df.string(from: day), slots: slots)
        }

        let weekOfYear = Date.mondayCalendar.component(.weekOfYear, from: start)
        return WeekExportData(
            title: "\(householdName) · \(String(localized: "Week")) \(weekOfYear)",
            days: days
        )
    }

    /// Render the week to a one-page PDF and return the temp file URL.
    @MainActor
    static func pdf(_ data: WeekExportData) -> URL? {
        let view = WeekPrintView(data: data).frame(width: 842, height: 595) // A4 landscape @72dpi
        let renderer = ImageRenderer(content: view)
        renderer.proposedSize = .init(width: 842, height: 595)

        let url = FileManager.default.temporaryDirectory
            .appending(path: "MealPlan-\(Int(Date.now.timeIntervalSince1970)).pdf")

        var success = false
        renderer.render { size, renderInContext in
            var box = CGRect(origin: .zero, size: size)
            guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { return }
            ctx.beginPDFPage(nil)
            renderInContext(ctx)
            ctx.endPDFPage()
            ctx.closePDF()
            success = true
        }
        return success ? url : nil
    }
}

struct WeekPrintView: View {
    let data: WeekExportData

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(data.title)
                .font(.title2.bold())

            HStack(alignment: .top, spacing: 8) {
                ForEach(data.days) { day in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(day.title)
                            .font(.caption.bold())
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.bottom, 2)
                            .overlay(alignment: .bottom) { Divider() }
                        ForEach(day.slots) { slot in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(slot.name).font(.system(size: 8)).foregroundStyle(.secondary)
                                if slot.dishes.isEmpty {
                                    Text("—").font(.system(size: 9)).foregroundStyle(.tertiary)
                                } else {
                                    ForEach(slot.dishes, id: \.self) { name in
                                        Text(name).font(.system(size: 9))
                                    }
                                }
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
        }
        .padding(24)
        .frame(width: 842, height: 595, alignment: .topLeading)
        .background(.white)
        .environment(\.colorScheme, .light)
    }
}
