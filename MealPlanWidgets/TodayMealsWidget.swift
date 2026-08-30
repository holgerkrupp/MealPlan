import WidgetKit
import SwiftUI
import SwiftData
#if canImport(UIKit)
import UIKit
#endif

struct MealLine: Identifiable, Hashable {
    var id = UUID()
    var slot: String
    var dishName: String
    var imageData: Data?
    /// The dish's placeholder glyph, used when there's no photo.
    var glyphRaw: String?

    var glyph: DishGlyph? { glyphRaw.flatMap(DishGlyph.init(rawValue:)) }
}

struct MealPlanEntryTimeline: TimelineEntry {
    var date: Date
    var headline: String
    var lines: [MealLine]
}

struct TodayMealsProvider: TimelineProvider {
    func placeholder(in context: Context) -> MealPlanEntryTimeline {
        MealPlanEntryTimeline(date: .now, headline: String(localized: "Today"), lines: [
            MealLine(slot: String(localized: "Lunch"), dishName: "Pfannkuchen", imageData: nil),
            MealLine(slot: String(localized: "Dinner"), dishName: "Spaghetti Bolognese", imageData: nil),
        ])
    }

    func getSnapshot(in context: Context, completion: @escaping (MealPlanEntryTimeline) -> Void) {
        completion(load())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<MealPlanEntryTimeline>) -> Void) {
        let entry = load()
        let cal = Calendar.current
        let nextRefresh = cal.nextDate(after: .now, matching: DateComponents(minute: 0), matchingPolicy: .nextTime)
            ?? Date.now.addingTimeInterval(3600)
        completion(Timeline(entries: [entry], policy: .after(nextRefresh)))
    }

    private func load() -> MealPlanEntryTimeline {
        do {
            let container = SharedStore.container(cloudKit: false)
            let context = ModelContext(container)
            let now = Date.now
            let showTomorrow = Calendar.current.component(.hour, from: now) >= 18
            let dayStart = (showTomorrow ? now.adding(days: 1) : now).startOfDay
            let dayEnd = dayStart.adding(days: 1)

            let descriptor = FetchDescriptor<MealPlanEntry>(
                predicate: #Predicate { $0.date >= dayStart && $0.date < dayEnd && $0.skipped == false },
                sortBy: [SortDescriptor(\.sortIndex)]
            )
            let entries = (try? context.fetch(descriptor)) ?? []

            let mealTypes = (try? context.fetch(FetchDescriptor<MealType>())) ?? []
            let order = Dictionary(uniqueKeysWithValues: mealTypes.map { ($0.key, $0.sortOrder) })
            let names = Dictionary(uniqueKeysWithValues: mealTypes.map { ($0.key, $0.name) })
            func rank(_ e: MealPlanEntry) -> Int { order[e.mealKey] ?? (1000 + e.slot.sortOrder) }
            func label(_ e: MealPlanEntry) -> String { names[e.mealKey] ?? MealType.legacyName(for: e.mealKey) }

            let lines = entries
                .sorted { (rank($0), $0.sortIndex) < (rank($1), $1.sortIndex) }
                .map {
                    MealLine(
                        slot: label($0),
                        dishName: $0.displayTitle,
                        imageData: $0.dish?.primaryImageData,
                        glyphRaw: $0.dish?.glyphRaw
                    )
                }

            return MealPlanEntryTimeline(
                date: now,
                headline: showTomorrow ? String(localized: "Tomorrow") : String(localized: "Today"),
                lines: lines
            )
        }
    }
}

struct TodayMealsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "TodayMealsWidget", provider: TodayMealsProvider()) { entry in
            TodayMealsView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName(String(localized: "Today’s meals"))
        .description(String(localized: "What’s planned for today."))
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular])
    }
}

struct TodayMealsView: View {
    var entry: MealPlanEntryTimeline
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryRectangular:
            VStack(alignment: .leading) {
                Text(entry.headline).font(.headline)
                ForEach(entry.lines.prefix(2)) { line in
                    Text("\(line.slot): \(line.dishName)").font(.caption).lineLimit(1)
                }
                if entry.lines.isEmpty { Text(String(localized: "Nothing planned")).font(.caption) }
            }
        default:
            VStack(alignment: .leading, spacing: 6) {
                Text(entry.headline)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if entry.lines.isEmpty {
                    Spacer()
                    Text(String(localized: "Nothing planned yet"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer()
                } else {
                    ForEach(entry.lines.prefix(family == .systemSmall ? 2 : 4)) { line in
                        HStack(spacing: 6) {
                            if let data = line.imageData, let image = Image(widgetData: data) {
                                image.resizable().scaledToFill()
                                    .frame(width: 22, height: 22)
                                    .clipShape(RoundedRectangle(cornerRadius: 5))
                            } else {
                                glyphTile(for: line)
                            }
                            VStack(alignment: .leading, spacing: 0) {
                                Text(line.slot).font(.system(size: 9)).foregroundStyle(.secondary)
                                Text(line.dishName).font(.caption).lineLimit(1)
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    /// The dish's own emoji / symbol placeholder, falling back to the generic
    /// fork-and-knife when it hasn't got one.
    @ViewBuilder
    private func glyphTile(for line: MealLine) -> some View {
        let tint = DishGlyph.tint(forName: line.dishName)
        switch line.glyph {
        case .emoji(let value):
            Text(value)
                .font(.system(size: 13))
                .frame(width: 22, height: 22)
                .background(tint.opacity(0.18), in: RoundedRectangle(cornerRadius: 5))
        case .symbol(let name):
            Image(systemName: name)
                .font(.caption2)
                .foregroundStyle(tint)
                .frame(width: 22, height: 22)
                .background(tint.opacity(0.18), in: RoundedRectangle(cornerRadius: 5))
        case nil:
            Image(systemName: "fork.knife")
                .font(.caption2)
                .frame(width: 22, height: 22)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
        }
    }
}

extension Image {
    init?(widgetData data: Data) {
        #if canImport(UIKit)
        guard let ui = UIImage(data: data) else { return nil }
        self.init(uiImage: ui)
        #else
        return nil
        #endif
    }
}
