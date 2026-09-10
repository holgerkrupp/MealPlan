import SwiftData
import SwiftUI

#if os(iOS)
import UIKit
private typealias MealSharePlatformImage = UIImage
#elseif os(macOS)
import AppKit
private typealias MealSharePlatformImage = NSImage
#endif

// MARK: - Share period

enum MealSharePeriod: String, CaseIterable, Identifiable {
    case week
    case month
    case year

    var id: Self { self }

    var title: String {
        switch self {
        case .week: String(localized: "Week")
        case .month: String(localized: "Month")
        case .year: String(localized: "Year")
        }
    }

    func interval(containing date: Date, calendar: Calendar = .autoupdatingCurrent) -> DateInterval {
        let component: Calendar.Component = switch self {
        case .week: .weekOfYear
        case .month: .month
        case .year: .year
        }
        return calendar.dateInterval(of: component, for: date)
            ?? DateInterval(start: date.startOfDay, duration: 86_400)
    }

    func adding(_ amount: Int, to date: Date, calendar: Calendar = .autoupdatingCurrent) -> Date {
        let component: Calendar.Component = switch self {
        case .week: .weekOfYear
        case .month: .month
        case .year: .year
        }
        return calendar.date(byAdding: component, value: amount, to: date) ?? date
    }

    func label(for date: Date, calendar: Calendar = .autoupdatingCurrent) -> String {
        let interval = interval(containing: date, calendar: calendar)
        switch self {
        case .week:
            let inclusiveEnd = calendar.date(byAdding: .day, value: -1, to: interval.end) ?? interval.end
            return interval.start.formatted(.dateTime.day().month(.abbreviated))
                + " – "
                + inclusiveEnd.formatted(.dateTime.day().month(.abbreviated).year())
        case .month:
            return interval.start.formatted(.dateTime.month(.wide).year())
        case .year:
            return interval.start.formatted(.dateTime.year())
        }
    }
}

private enum MealShareDesign: String, CaseIterable, Identifiable {
    case overview
    case monthCalendar
    case history
    case frequency
    case nutrition
    case nutritionTrend

    var id: Self { self }

    var title: String {
        switch self {
        case .overview: String(localized: "At a Glance")
        case .monthCalendar: String(localized: "Meal Calendar")
        case .history: String(localized: "Cooked Meals")
        case .frequency: String(localized: "Meal Favorites")
        case .nutrition: String(localized: "Nutrition")
        case .nutritionTrend: String(localized: "Nutrition over Time")
        }
    }

    var filename: String {
        rawValue
            .replacingOccurrences(of: "monthCalendar", with: "meal-calendar")
            .replacingOccurrences(of: "nutritionTrend", with: "nutrition-trend")
    }
}

private enum MealShareBackground: String, CaseIterable, Identifiable {
    case cookbook
    case citrus
    case garden
    case midnight
    case paper

    var id: Self { self }

    var title: String {
        switch self {
        case .cookbook: String(localized: "Cookbook")
        case .citrus: String(localized: "Citrus")
        case .garden: String(localized: "Garden")
        case .midnight: String(localized: "Midnight")
        case .paper: String(localized: "Paper")
        }
    }

    var isLight: Bool { self == .paper || self == .citrus }
}

/// Shared with the recipe images, so every picture MealPlan hands to social
/// media comes in the same three sizes.
enum MealShareAspect: String, CaseIterable, Identifiable {
    case portrait
    case square
    case landscape

    var id: Self { self }

    var title: String {
        switch self {
        case .portrait: String(localized: "Portrait")
        case .square: String(localized: "Square")
        case .landscape: String(localized: "Landscape")
        }
    }

    var renderSize: CGSize {
        switch self {
        case .portrait: CGSize(width: 1080, height: 1350)
        case .square: CGSize(width: 1080, height: 1080)
        case .landscape: CGSize(width: 1600, height: 900)
        }
    }

    var ratio: CGFloat { renderSize.width / renderSize.height }
}

// MARK: - Snapshot

struct MealShareOccurrence: Identifiable {
    let id: UUID
    let date: Date
    let name: String
    let servings: Int?
    let glyph: DishGlyph?
}

struct MealShareRank: Identifiable {
    let id: String
    let name: String
    let cookedCount: Int
    let plannedCount: Int
    let facts: NutritionFacts?
    let glyph: DishGlyph?

    var totalCount: Int { cookedCount + plannedCount }
}

struct MealShareNutritionPoint: Identifiable {
    let id: Date
    let date: Date
    let facts: NutritionFacts
    let mealCount: Int
}

struct MealShareCalendarMeal: Identifiable {
    let id: String
    let name: String
    let imageData: Data?
    let glyph: DishGlyph?
    let nutrition: NutritionFacts?
}

struct MealShareCalendarDay: Identifiable {
    let id: Date
    let date: Date
    let meals: [MealShareCalendarMeal]
    let nutrition: NutritionFacts?

    var primaryMeal: MealShareCalendarMeal? {
        meals.first(where: { $0.imageData != nil }) ?? meals.first
    }
}

struct MealShareSnapshot {
    let periodStart: Date
    let periodLabel: String
    let cookedCount: Int
    let plannedCount: Int
    let uniqueMealCount: Int
    let occurrences: [MealShareOccurrence]
    let rankings: [MealShareRank]
    let calendarDays: [MealShareCalendarDay]
    let nutritionPoints: [MealShareNutritionPoint]
    let nutritionMealCount: Int
    let averageNutrition: NutritionFacts?

    var hasContent: Bool { cookedCount > 0 || plannedCount > 0 }

    static func make(
        logs: [CookedLog],
        entries: [MealPlanEntry],
        householdID: UUID?,
        period: MealSharePeriod,
        date: Date,
        calendar: Calendar = .autoupdatingCurrent
    ) -> MealShareSnapshot {
        let interval = period.interval(containing: date, calendar: calendar)
        let matchingLogs = logs.filter {
            belongsToHousehold($0.household?.uuid, householdID: householdID)
                && interval.contains($0.date)
        }
        let matchingEntries = entries.filter {
            belongsToHousehold($0.household?.uuid, householdID: householdID)
                && interval.contains($0.date)
                && !$0.skipped
        }

        struct RankAccumulator {
            var name: String
            var cooked = 0
            var planned = 0
            var dish: Dish?
        }
        var rankByDish: [String: RankAccumulator] = [:]

        for log in matchingLogs {
            let name = nonEmpty(log.dish?.name) ?? nonEmpty(log.dishName) ?? String(localized: "Meal")
            let key = log.dish.map { "dish:\($0.uuid.uuidString)" }
                ?? "name:\(name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current))"
            var value = rankByDish[key] ?? RankAccumulator(name: name, dish: log.dish)
            value.cooked += 1
            if value.dish == nil { value.dish = log.dish }
            rankByDish[key] = value
        }
        for entry in matchingEntries where entry.dish != nil {
            guard let dish = entry.dish else { continue }
            let key = "dish:\(dish.uuid.uuidString)"
            var value = rankByDish[key] ?? RankAccumulator(name: dish.name, dish: dish)
            value.planned += 1
            rankByDish[key] = value
        }

        let rankings = rankByDish.map { key, value in
            let estimate = value.dish.map(NutritionEstimator.perServing(for:))
            return MealShareRank(
                id: key,
                name: value.name,
                cookedCount: value.cooked,
                plannedCount: value.planned,
                facts: estimate?.isTrustworthy == true ? estimate?.facts : nil,
                glyph: value.dish?.glyph
            )
        }
        .sorted {
            if $0.totalCount != $1.totalCount { return $0.totalCount > $1.totalCount }
            if $0.cookedCount != $1.cookedCount { return $0.cookedCount > $1.cookedCount }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }

        let occurrences = matchingLogs
            .sorted { $0.date > $1.date }
            .map {
                MealShareOccurrence(
                    id: $0.uuid,
                    date: $0.date,
                    name: nonEmpty($0.dish?.name) ?? nonEmpty($0.dishName) ?? String(localized: "Meal"),
                    servings: $0.servings,
                    glyph: $0.dish?.glyph
                )
            }

        // A completed plan has both an entry and a cooked log. Use the log in
        // that case so each dish appears once, and prefer the photo captured
        // when it was cooked over the recipe's primary photo.
        var calendarMealsByDay: [Date: [MealShareCalendarMeal]] = [:]
        func addCalendarMeal(
            id: String,
            date: Date,
            name: String,
            dish: Dish?,
            imageData: Data?
        ) {
            let estimate = dish.map(NutritionEstimator.perServing(for:))
            let meal = MealShareCalendarMeal(
                id: id,
                name: name,
                imageData: imageData,
                glyph: dish?.glyph,
                nutrition: estimate?.isTrustworthy == true ? estimate?.facts : nil
            )
            calendarMealsByDay[calendar.startOfDay(for: date), default: []].append(meal)
        }
        for log in matchingLogs.sorted(by: { $0.date < $1.date }) {
            addCalendarMeal(
                id: "log:\(log.uuid.uuidString)",
                date: log.date,
                name: nonEmpty(log.dish?.name) ?? nonEmpty(log.dishName) ?? String(localized: "Meal"),
                dish: log.dish,
                imageData: log.photoData ?? log.dish?.primaryImageData
            )
        }
        for entry in matchingEntries
            .filter({ $0.cookedLog == nil })
            .sorted(by: {
                if $0.date != $1.date { return $0.date < $1.date }
                if $0.mealKey != $1.mealKey { return $0.mealKey < $1.mealKey }
                return $0.sortIndex < $1.sortIndex
            }) {
            addCalendarMeal(
                id: "entry:\(entry.uuid.uuidString)",
                date: entry.date,
                name: entry.displayTitle,
                dish: entry.dish,
                imageData: entry.dish?.primaryImageData
            )
        }
        let calendarDays = calendarMealsByDay
            .map { date, meals in
                let nutritionValues = meals.compactMap(\.nutrition)
                let total = nutritionValues.isEmpty
                    ? nil
                    : nutritionValues.reduce(NutritionFacts.zero, +)
                return MealShareCalendarDay(id: date, date: date, meals: meals, nutrition: total)
            }
            .sorted { $0.date < $1.date }

        // Cooked logs represent the past. Uncooked plan entries supplement them
        // for today and the future, so a current period can show what is coming
        // without counting a completed plan twice.
        var nutritionByDay: [Date: (facts: NutritionFacts, count: Int)] = [:]
        func addNutrition(_ dish: Dish?, on date: Date) {
            guard let dish else { return }
            let estimate = NutritionEstimator.perServing(for: dish)
            guard estimate.isTrustworthy else { return }
            let day = calendar.startOfDay(for: date)
            var value = nutritionByDay[day] ?? (.zero, 0)
            value.facts += estimate.facts
            value.count += 1
            nutritionByDay[day] = value
        }
        for log in matchingLogs { addNutrition(log.dish, on: log.date) }
        for entry in matchingEntries where entry.cookedLog == nil && entry.date >= calendar.startOfDay(for: .now) {
            addNutrition(entry.dish, on: entry.date)
        }

        let points = chartPoints(
            nutritionByDay: nutritionByDay,
            interval: interval,
            period: period,
            calendar: calendar
        )
        let nutritionMealCount = nutritionByDay.values.reduce(0) { $0 + $1.count }
        let totalNutrition = nutritionByDay.values.reduce(NutritionFacts.zero) { $0 + $1.facts }
        let average = nutritionMealCount > 0
            ? totalNutrition.scaled(by: 1 / Double(nutritionMealCount))
            : nil

        return MealShareSnapshot(
            periodStart: interval.start,
            periodLabel: period.label(for: date, calendar: calendar),
            cookedCount: matchingLogs.count,
            plannedCount: matchingEntries.count,
            uniqueMealCount: rankByDish.count,
            occurrences: occurrences,
            rankings: rankings,
            calendarDays: calendarDays,
            nutritionPoints: points,
            nutritionMealCount: nutritionMealCount,
            averageNutrition: average
        )
    }

    private static func belongsToHousehold(_ candidateID: UUID?, householdID: UUID?) -> Bool {
        guard let householdID else { return true }
        return candidateID == householdID
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func chartPoints(
        nutritionByDay: [Date: (facts: NutritionFacts, count: Int)],
        interval: DateInterval,
        period: MealSharePeriod,
        calendar: Calendar
    ) -> [MealShareNutritionPoint] {
        let bucket: Calendar.Component = period == .year ? .month : .day
        var cursor = interval.start
        var points: [MealShareNutritionPoint] = []
        while cursor < interval.end {
            let next = calendar.date(byAdding: bucket, value: 1, to: cursor) ?? interval.end
            let values = nutritionByDay.filter { $0.key >= cursor && $0.key < next }.map(\.value)
            let facts = values.reduce(NutritionFacts.zero) { $0 + $1.facts }
            let count = values.reduce(0) { $0 + $1.count }
            points.append(MealShareNutritionPoint(id: cursor, date: cursor, facts: facts, mealCount: count))
            cursor = next
        }
        return points
    }
}

// MARK: - Gallery

@MainActor
struct MealShareGalleryView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @Query(sort: \CookedLog.date, order: .reverse) private var cookedLogs: [CookedLog]
    @Query(sort: \MealPlanEntry.date, order: .forward) private var planEntries: [MealPlanEntry]

    @State private var selectedPeriod: MealSharePeriod = .month
    @State private var selectedDate: Date
    @State private var shareTitle = String(localized: "My Meals")
    @State private var background: MealShareBackground = .cookbook
    @State private var aspect: MealShareAspect = .portrait
    @State private var renderedImages: [MealShareDesign: MealSharePlatformImage] = [:]
    @State private var renderedFiles: [MealShareDesign: URL] = [:]
    @State private var selectedDesigns = Set<MealShareDesign>()
    @State private var isRendering = false
    @State private var renderedCount = 0
    @State private var renderDirectory: URL?

    init(initialDate: Date = .now) {
        _selectedDate = State(initialValue: initialDate)
    }

    private var snapshot: MealShareSnapshot {
        MealShareSnapshot.make(
            logs: cookedLogs,
            entries: planEntries,
            householdID: appState.currentHousehold?.uuid,
            period: selectedPeriod,
            date: selectedDate
        )
    }

    private var availableDesigns: [MealShareDesign] {
        Self.availableDesigns(for: snapshot, period: selectedPeriod)
    }

    private static func availableDesigns(
        for snapshot: MealShareSnapshot,
        period: MealSharePeriod
    ) -> [MealShareDesign] {
        MealShareDesign.allCases.filter { design in
            switch design {
            case .overview: snapshot.hasContent
            case .monthCalendar: period == .month && snapshot.hasContent
            case .history: !snapshot.occurrences.isEmpty
            case .frequency: !snapshot.rankings.isEmpty
            case .nutrition: snapshot.averageNutrition != nil
            case .nutritionTrend: snapshot.nutritionMealCount > 0
            }
        }
    }

    private var effectiveTitle: String {
        let trimmed = shareTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? String(localized: "My Meals") : trimmed
    }

    private var dataSignature: String {
        let logs = cookedLogs.map {
            "\($0.uuid):\($0.modifiedAt.timeIntervalSinceReferenceDate):\($0.dish?.modifiedAt.timeIntervalSinceReferenceDate ?? 0)"
        }.joined(separator: ";")
        let entries = planEntries.map {
            "\($0.uuid):\($0.modifiedAt.timeIntervalSinceReferenceDate):\($0.dish?.modifiedAt.timeIntervalSinceReferenceDate ?? 0)"
        }.joined(separator: ";")
        return "\(appState.currentHousehold?.uuid.uuidString ?? "all")|\(selectedPeriod.rawValue)|\(selectedDate.timeIntervalSinceReferenceDate)|\(effectiveTitle)|\(background.rawValue)|\(aspect.rawValue)|\(appState.energyUnit.rawValue)|\(logs)|\(entries)"
    }

    private var selectedFileURLs: [URL] {
        MealShareDesign.allCases.compactMap { selectedDesigns.contains($0) ? renderedFiles[$0] : nil }
    }

    private var canMoveForward: Bool {
        selectedPeriod.interval(containing: selectedDate).start
            < selectedPeriod.interval(containing: .now).start
    }

    var body: some View {
        List {
            Section {
                Picker(String(localized: "Period"), selection: $selectedPeriod) {
                    ForEach(MealSharePeriod.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)

                HStack(spacing: 12) {
                    Button { selectedDate = selectedPeriod.adding(-1, to: selectedDate) } label: {
                        Image(systemName: "chevron.left")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel(String(localized: "Previous period"))

                    Spacer()
                    Text(selectedPeriod.label(for: selectedDate))
                        .font(.subheadline.weight(.semibold))
                        .multilineTextAlignment(.center)
                    Spacer()

                    Button { selectedDate = selectedPeriod.adding(1, to: selectedDate) } label: {
                        Image(systemName: "chevron.right")
                    }
                    .buttonStyle(.bordered)
                    .disabled(!canMoveForward)
                    .accessibilityLabel(String(localized: "Next period"))
                }
            }

            if !snapshot.hasContent {
                ContentUnavailableView(
                    String(localized: "No meals to share"),
                    systemImage: "photo.on.rectangle.angled",
                    description: Text(String(localized: "There are no cooked or planned meals in this time span."))
                )
            } else {
                Section {
                    NavigationLink {
                        MealShareCustomizeView(title: $shareTitle, background: $background, aspect: $aspect)
                    } label: {
                        Label(String(localized: "Customize"), systemImage: "slider.horizontal.3")
                    }
                } footer: {
                    Text("\(effectiveTitle) · \(aspect.title) · \(background.title)")
                }

                Section {
                    if isRendering {
                        VStack(alignment: .leading, spacing: 8) {
                            ProgressView(value: Double(renderedCount), total: Double(max(availableDesigns.count, 1)))
                            Text(String(localized: "Rendering \(renderedCount) of \(availableDesigns.count) share images"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        .padding(.vertical, 4)
                    }

                    LazyVGrid(
                        columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                        spacing: 12
                    ) {
                        ForEach(availableDesigns) { design in
                            MealSharePreviewTile(
                                design: design,
                                image: renderedImages[design],
                                fileURL: renderedFiles[design],
                                aspectRatio: aspect.ratio,
                                isSelected: selectedDesigns.contains(design)
                            ) { toggleSelection(design) }
                        }
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text(String(localized: "Designs"))
                } footer: {
                    Text(String(localized: "Tap images to select several. Nutrition figures are estimates per person and all statistics are calculated on this device."))
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            }
        }
        .navigationTitle(String(localized: "Share Images"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(String(localized: "Done")) { dismiss() }
            }
            ToolbarItem(placement: .primaryAction) {
                ShareLink(items: selectedFileURLs) {
                    Image(systemName: "square.and.arrow.up")
                }
                .disabled(selectedFileURLs.isEmpty)
                .accessibilityLabel(
                    selectedDesigns.count == 1
                        ? String(localized: "Share Selected Image")
                        : String(localized: "Share Selected Images")
                )
            }
        }
        .task(id: dataSignature) { await renderImages() }
        .onDisappear { removeRenderDirectory() }
        #if os(macOS)
        .frame(minWidth: 620, idealWidth: 720, minHeight: 650)
        #endif
    }

    private func toggleSelection(_ design: MealShareDesign) {
        if selectedDesigns.contains(design) {
            selectedDesigns.remove(design)
        } else {
            selectedDesigns.insert(design)
        }
    }

    private func renderImages() async {
        let currentSnapshot = snapshot
        let designs = Self.availableDesigns(for: currentSnapshot, period: selectedPeriod)
        removeRenderDirectory()
        renderedImages = [:]
        renderedFiles = [:]
        renderedCount = 0
        selectedDesigns.formIntersection(Set(designs))
        guard !designs.isEmpty else { return }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MealPlanShareImages", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        renderDirectory = directory
        isRendering = true
        defer { isRendering = false }

        for design in designs {
            guard !Task.isCancelled else { return }
            let renderer = ImageRenderer(
                content: MealShareCard(
                    snapshot: currentSnapshot,
                    design: design,
                    title: effectiveTitle,
                    background: background,
                    aspect: aspect,
                    energyUnit: appState.energyUnit
                )
                .frame(width: aspect.renderSize.width, height: aspect.renderSize.height)
            )
            renderer.scale = 1
            if let image = platformImage(from: renderer) {
                renderedImages[design] = image
                if let data = pngData(for: image) {
                    let url = directory.appendingPathComponent("mealplan-\(design.filename).png")
                    try? data.write(to: url, options: .atomic)
                    renderedFiles[design] = url
                }
            }
            renderedCount += 1
            await Task.yield()
        }
    }

    private func removeRenderDirectory() {
        if let renderDirectory { try? FileManager.default.removeItem(at: renderDirectory) }
        renderDirectory = nil
    }

    private func platformImage(from renderer: ImageRenderer<some View>) -> MealSharePlatformImage? {
        #if os(iOS)
        renderer.uiImage
        #elseif os(macOS)
        renderer.nsImage
        #endif
    }

    private func pngData(for image: MealSharePlatformImage) -> Data? {
        #if os(iOS)
        image.pngData()
        #elseif os(macOS)
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
        #endif
    }
}

private struct MealSharePreviewTile: View {
    let design: MealShareDesign
    let image: MealSharePlatformImage?
    let fileURL: URL?
    let aspectRatio: CGFloat
    let isSelected: Bool
    let selectAction: () -> Void

    var body: some View {
        VStack(spacing: 7) {
            Button(action: selectAction) {
                ZStack(alignment: .topTrailing) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.secondary.opacity(0.12))
                        if let image {
                            platformImage(image)
                                .resizable()
                                .scaledToFit()
                        } else {
                            ProgressView()
                        }
                    }
                    .aspectRatio(aspectRatio, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, isSelected ? Color.accentColor : Color.black.opacity(0.35))
                        .padding(7)
                }
                .padding(7)
                .background(
                    isSelected ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.18), lineWidth: isSelected ? 2.5 : 1)
                }
            }
            .buttonStyle(.plain)

            HStack {
                Text(design.title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let fileURL, let image {
                    ShareLink(
                        item: fileURL,
                        preview: SharePreview(design.title, image: platformImage(image))
                    ) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(String(localized: "Share \(design.title)"))
                }
            }
        }
    }

    private func platformImage(_ image: MealSharePlatformImage) -> Image {
        #if os(iOS)
        Image(uiImage: image)
        #elseif os(macOS)
        Image(nsImage: image)
        #endif
    }
}

// MARK: - Customization

private struct MealShareCustomizeView: View {
    @Binding var title: String
    @Binding var background: MealShareBackground
    @Binding var aspect: MealShareAspect

    var body: some View {
        Form {
            Section(String(localized: "Share Image Title")) {
                TextField(String(localized: "Title"), text: $title)
                Button(String(localized: "Reset to Default")) { title = String(localized: "My Meals") }
            }

            Section(String(localized: "Aspect Ratio")) {
                Picker(String(localized: "Aspect Ratio"), selection: $aspect) {
                    ForEach(MealShareAspect.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            Section(String(localized: "Background")) {
                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                    spacing: 12
                ) {
                    ForEach(MealShareBackground.allCases) { option in
                        Button { background = option } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                MealShareBackgroundView(background: option)
                                    .frame(height: 70)
                                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .stroke(
                                                background == option ? Color.accentColor : Color.secondary.opacity(0.25),
                                                lineWidth: background == option ? 3 : 1
                                            )
                                    }
                                Label(option.title, systemImage: background == option ? "checkmark.circle.fill" : "circle")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(background == option ? Color.accentColor : Color.primary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .navigationTitle(String(localized: "Customize"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

// MARK: - Rendered cards

private struct MealShareCard: View {
    let snapshot: MealShareSnapshot
    let design: MealShareDesign
    let title: String
    let background: MealShareBackground
    let aspect: MealShareAspect
    let energyUnit: EnergyUnit

    private var size: CGSize { aspect.renderSize }
    private var isLandscape: Bool { aspect == .landscape }
    private var scale: CGFloat { isLandscape ? 0.76 : (aspect == .square ? 0.86 : 1) }
    private var primary: Color { background.isLight ? .black.opacity(0.88) : .white }
    private var secondary: Color { primary.opacity(0.68) }
    private var cardFill: Color { background.isLight ? .white.opacity(0.68) : .white.opacity(0.13) }
    private var accent: Color { background == .garden ? .mint : (background == .citrus ? .orange : .pink) }

    var body: some View {
        ZStack {
            MealShareBackgroundView(background: background)
            VStack(alignment: .leading, spacing: 34 * scale) {
                header
                Group {
                    switch design {
                    case .overview: overview
                    case .monthCalendar: monthCalendar
                    case .history: history
                    case .frequency: frequency
                    case .nutrition: nutrition
                    case .nutritionTrend: nutritionTrend
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                footer
            }
            .padding(isLandscape ? 66 : 72)
        }
        .frame(width: size.width, height: size.height)
        .foregroundStyle(primary)
        .clipped()
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 8 * scale) {
                Text(title)
                    .font(.system(size: 58 * scale, weight: .heavy, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                Text(snapshot.periodLabel)
                    .font(.system(size: 27 * scale, weight: .semibold, design: .rounded))
                    .foregroundStyle(secondary)
            }
            Spacer()
            Image(systemName: "fork.knife.circle.fill")
                .font(.system(size: 64 * scale))
                .foregroundStyle(accent)
        }
    }

    private var footer: some View {
        HStack {
            Label("MealPlan", systemImage: "fork.knife")
                .font(.system(size: 22 * scale, weight: .bold, design: .rounded))
            Spacer()
            Text(String(localized: "Nutrition is estimated"))
                .font(.system(size: 17 * scale, weight: .medium, design: .rounded))
                .foregroundStyle(secondary)
        }
    }

    private var monthCalendar: some View {
        let calendar = Calendar.autoupdatingCurrent
        let spacing: CGFloat = 7 * scale
        let dayByDate = Dictionary(
            uniqueKeysWithValues: snapshot.calendarDays.map {
                (calendar.startOfDay(for: $0.date), $0)
            }
        )

        return VStack(spacing: spacing) {
            HStack(spacing: spacing) {
                ForEach(monthWeekdayLabels(calendar: calendar), id: \.self) { label in
                    Text(label)
                        .font(.system(size: 17 * scale, weight: .black, design: .rounded))
                        .foregroundStyle(secondary)
                        .frame(maxWidth: .infinity)
                        .lineLimit(1)
                }
            }

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: spacing), count: 7),
                spacing: spacing
            ) {
                ForEach(Array(monthGridDates(calendar: calendar).enumerated()), id: \.offset) { _, date in
                    if let date {
                        MealShareMonthDayCell(
                            date: date,
                            day: dayByDate[calendar.startOfDay(for: date)],
                            energyUnit: energyUnit,
                            primary: primary,
                            secondary: secondary,
                            scale: scale
                        )
                        .aspectRatio(monthCellAspectRatio, contentMode: .fit)
                    } else {
                        RoundedRectangle(cornerRadius: 8 * scale, style: .continuous)
                            .fill(primary.opacity(background.isLight ? 0.035 : 0.055))
                            .aspectRatio(monthCellAspectRatio, contentMode: .fit)
                    }
                }
            }
        }
    }

    private var monthCellAspectRatio: CGFloat {
        switch aspect {
        case .portrait: 1
        case .square: 1.18
        case .landscape: 2.35
        }
    }

    private func monthWeekdayLabels(calendar: Calendar) -> [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let firstIndex = calendar.firstWeekday - 1
        return (0..<7).map { symbols[(firstIndex + $0) % 7] }
    }

    private func monthGridDates(calendar: Calendar) -> [Date?] {
        let monthStart = snapshot.periodStart
        guard let days = calendar.range(of: .day, in: .month, for: monthStart) else { return [] }
        let firstWeekday = calendar.component(.weekday, from: monthStart)
        let leadingCount = (firstWeekday - calendar.firstWeekday + 7) % 7
        let dates = days.compactMap { day in
            calendar.date(byAdding: .day, value: day - 1, to: monthStart)
        }
        let trailingCount = (7 - ((leadingCount + dates.count) % 7)) % 7
        return Array(repeating: nil, count: leadingCount)
            + dates.map(Optional.some)
            + Array(repeating: nil, count: trailingCount)
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 34 * scale) {
            Text(MealShareDesign.overview.title)
                .font(.system(size: 38 * scale, weight: .bold, design: .rounded))
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 22 * scale), count: isLandscape ? 4 : 2), spacing: 22 * scale) {
                metricCard(value: "\(snapshot.cookedCount)", label: String(localized: "cooked"), symbol: "frying.pan.fill")
                metricCard(value: "\(snapshot.plannedCount)", label: String(localized: "planned"), symbol: "calendar")
                metricCard(value: "\(snapshot.uniqueMealCount)", label: String(localized: "different meals"), symbol: "square.grid.2x2.fill")
                metricCard(
                    value: snapshot.averageNutrition.map { energy($0) } ?? "–",
                    label: String(localized: "average per meal"),
                    symbol: "bolt.heart.fill"
                )
            }
            if let top = snapshot.rankings.first {
                HStack(spacing: 22 * scale) {
                    glyph(top.glyph, name: top.name, size: 86 * scale)
                    VStack(alignment: .leading, spacing: 5 * scale) {
                        Text(String(localized: "Most frequent"))
                            .font(.system(size: 21 * scale, weight: .semibold, design: .rounded))
                            .foregroundStyle(secondary)
                        Text(top.name)
                            .font(.system(size: 38 * scale, weight: .bold, design: .rounded))
                            .lineLimit(2)
                            .minimumScaleFactor(0.7)
                        Text(String(localized: "\(top.cookedCount) cooked · \(top.plannedCount) planned"))
                            .font(.system(size: 22 * scale, weight: .medium, design: .rounded))
                    }
                    Spacer()
                }
                .padding(28 * scale)
                .background(cardFill, in: RoundedRectangle(cornerRadius: 30 * scale, style: .continuous))
            }
        }
    }

    private func metricCard(value: String, label: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 10 * scale) {
            Image(systemName: symbol)
                .font(.system(size: 29 * scale, weight: .semibold))
                .foregroundStyle(accent)
            Text(value)
                .font(.system(size: 46 * scale, weight: .heavy, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label)
                .font(.system(size: 20 * scale, weight: .semibold, design: .rounded))
                .foregroundStyle(secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(25 * scale)
        .background(cardFill, in: RoundedRectangle(cornerRadius: 28 * scale, style: .continuous))
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 18 * scale) {
            Text(MealShareDesign.history.title)
                .font(.system(size: 38 * scale, weight: .bold, design: .rounded))
            let limit = isLandscape ? 5 : (aspect == .square ? 6 : 8)
            ForEach(Array(snapshot.occurrences.prefix(limit).enumerated()), id: \.element.id) { index, meal in
                HStack(spacing: 20 * scale) {
                    glyph(meal.glyph, name: meal.name, size: 66 * scale)
                    VStack(alignment: .leading, spacing: 3 * scale) {
                        Text(meal.name)
                            .font(.system(size: 27 * scale, weight: .bold, design: .rounded))
                            .lineLimit(1)
                        Text(meal.date.formatted(date: .abbreviated, time: .omitted))
                            .font(.system(size: 18 * scale, weight: .medium, design: .rounded))
                            .foregroundStyle(secondary)
                    }
                    Spacer()
                    if let servings = meal.servings {
                        Label("\(servings)", systemImage: "person.2.fill")
                            .font(.system(size: 18 * scale, weight: .semibold, design: .rounded))
                            .foregroundStyle(secondary)
                    }
                }
                .padding(.horizontal, 22 * scale)
                .padding(.vertical, 14 * scale)
                .background(cardFill.opacity(index.isMultiple(of: 2) ? 1 : 0.72), in: RoundedRectangle(cornerRadius: 22 * scale))
            }
        }
    }

    private var frequency: some View {
        VStack(alignment: .leading, spacing: 20 * scale) {
            Text(MealShareDesign.frequency.title)
                .font(.system(size: 38 * scale, weight: .bold, design: .rounded))
            let rows = Array(snapshot.rankings.prefix(isLandscape ? 5 : 7))
            let maximum = max(rows.map(\.totalCount).max() ?? 1, 1)
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, meal in
                HStack(spacing: 18 * scale) {
                    Text("\(index + 1)")
                        .font(.system(size: 25 * scale, weight: .heavy, design: .rounded))
                        .frame(width: 34 * scale)
                        .foregroundStyle(accent)
                    glyph(meal.glyph, name: meal.name, size: 58 * scale)
                    VStack(alignment: .leading, spacing: 8 * scale) {
                        HStack {
                            Text(meal.name)
                                .font(.system(size: 25 * scale, weight: .bold, design: .rounded))
                                .lineLimit(1)
                            Spacer()
                            Text(String(localized: "\(meal.cookedCount) cooked · \(meal.plannedCount) planned"))
                                .font(.system(size: 16 * scale, weight: .semibold, design: .rounded))
                                .foregroundStyle(secondary)
                        }
                        GeometryReader { geometry in
                            Capsule()
                                .fill(primary.opacity(0.12))
                                .overlay(alignment: .leading) {
                                    Capsule()
                                        .fill(accent)
                                        .frame(width: geometry.size.width * CGFloat(meal.totalCount) / CGFloat(maximum))
                                }
                        }
                        .frame(height: 13 * scale)
                    }
                }
                .padding(.horizontal, 18 * scale)
                .padding(.vertical, 12 * scale)
                .background(cardFill, in: RoundedRectangle(cornerRadius: 21 * scale))
            }
        }
    }

    private var nutrition: some View {
        VStack(alignment: .leading, spacing: 30 * scale) {
            Text(MealShareDesign.nutrition.title)
                .font(.system(size: 38 * scale, weight: .bold, design: .rounded))
            if let facts = snapshot.averageNutrition {
                HStack(alignment: .firstTextBaseline, spacing: 13 * scale) {
                    Text(energy(facts))
                        .font(.system(size: 78 * scale, weight: .heavy, design: .rounded))
                        .minimumScaleFactor(0.65)
                    Text(String(localized: "average per meal"))
                        .font(.system(size: 22 * scale, weight: .semibold, design: .rounded))
                        .foregroundStyle(secondary)
                }
                .padding(30 * scale)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(cardFill, in: RoundedRectangle(cornerRadius: 32 * scale))

                HStack(spacing: 18 * scale) {
                    macroCard(String(localized: "Protein"), grams(facts.proteinGrams), color: .pink)
                    macroCard(String(localized: "Carbs"), grams(facts.carbGrams), color: .orange)
                    macroCard(String(localized: "Fat"), grams(facts.fatGrams), color: .mint)
                }

                Text(String(localized: "Based on \(snapshot.nutritionMealCount) meals with enough nutrition information."))
                    .font(.system(size: 22 * scale, weight: .medium, design: .rounded))
                    .foregroundStyle(secondary)
            }
        }
    }

    private func macroCard(_ label: String, _ value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 12 * scale) {
            Circle().fill(color).frame(width: 18 * scale, height: 18 * scale)
            Text(value)
                .font(.system(size: 36 * scale, weight: .heavy, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.65)
            Text(label)
                .font(.system(size: 19 * scale, weight: .semibold, design: .rounded))
                .foregroundStyle(secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(24 * scale)
        .background(cardFill, in: RoundedRectangle(cornerRadius: 27 * scale))
    }

    private var nutritionTrend: some View {
        VStack(alignment: .leading, spacing: 24 * scale) {
            HStack(alignment: .firstTextBaseline) {
                Text(MealShareDesign.nutritionTrend.title)
                    .font(.system(size: 38 * scale, weight: .bold, design: .rounded))
                Spacer()
                if let average = snapshot.averageNutrition {
                    Text(String(localized: "Ø \(energy(average)) / meal"))
                        .font(.system(size: 20 * scale, weight: .semibold, design: .rounded))
                        .foregroundStyle(secondary)
                }
            }
            MealNutritionChart(
                points: snapshot.nutritionPoints,
                energyUnit: energyUnit,
                primary: primary,
                accent: accent,
                scale: scale
            )
            .frame(maxHeight: .infinity)
            HStack(spacing: 26 * scale) {
                chartLegend(color: accent, text: String(localized: "Estimated energy"))
                chartLegend(color: primary.opacity(0.22), text: String(localized: "Days without data"))
            }
        }
    }

    private func chartLegend(color: Color, text: String) -> some View {
        HStack(spacing: 8 * scale) {
            Circle().fill(color).frame(width: 12 * scale, height: 12 * scale)
            Text(text).font(.system(size: 17 * scale, weight: .semibold, design: .rounded)).foregroundStyle(secondary)
        }
    }

    private func energy(_ facts: NutritionFacts) -> String {
        let value = Int(facts.energy(in: energyUnit).rounded())
        return "\(value.formatted()) \(energyUnit.symbol)"
    }

    private func grams(_ value: Double) -> String { "\(Int(value.rounded()).formatted()) g" }

    @ViewBuilder
    private func glyph(_ dishGlyph: DishGlyph?, name: String, size: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
                .fill(DishGlyph.tint(forName: name).opacity(background.isLight ? 0.18 : 0.34))
            if let emoji = dishGlyph?.emoji {
                Text(emoji).font(.system(size: size * 0.54))
            } else {
                Image(systemName: dishGlyph?.symbolName ?? "fork.knife")
                    .font(.system(size: size * 0.40, weight: .semibold))
                    .foregroundStyle(primary.opacity(0.78))
            }
        }
        .frame(width: size, height: size)
    }
}

private struct MealShareMonthDayCell: View {
    let date: Date
    let day: MealShareCalendarDay?
    let energyUnit: EnergyUnit
    let primary: Color
    let secondary: Color
    let scale: CGFloat

    private var meal: MealShareCalendarMeal? { day?.primaryMeal }
    private var hasPhoto: Bool { meal?.imageData != nil }
    private var contentColor: Color { day == nil ? primary : .white }

    var body: some View {
        ZStack {
            background

            LinearGradient(
                colors: [
                    .black.opacity(day == nil ? 0 : (hasPhoto ? 0.64 : 0.34)),
                    .black.opacity(day == nil ? 0 : 0.04),
                    .black.opacity(day == nil ? 0 : (hasPhoto ? 0.76 : 0.46))
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            VStack(alignment: .leading, spacing: 2 * scale) {
                HStack(alignment: .top, spacing: 3 * scale) {
                    Text(date.formatted(.dateTime.day()))
                        .font(.system(size: 17 * scale, weight: .black, design: .rounded))
                    Spacer(minLength: 0)
                    if let day, day.meals.count > 1 {
                        Text("+\(day.meals.count - 1)")
                            .font(.system(size: 10 * scale, weight: .black, design: .rounded))
                            .padding(.horizontal, 4 * scale)
                            .padding(.vertical, 2 * scale)
                            .background(.black.opacity(0.38), in: Capsule())
                    }
                }

                Spacer(minLength: 0)

                if let meal {
                    Text(meal.name)
                        .font(.system(size: 11 * scale, weight: .black, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.55)
                    if let nutrition = day?.nutrition {
                        Text(energy(nutrition))
                            .font(.system(size: 9 * scale, weight: .bold, design: .rounded))
                            .lineLimit(1)
                            .minimumScaleFactor(0.55)
                            .monospacedDigit()
                        Text(macros(nutrition))
                            .font(.system(size: 7.5 * scale, weight: .semibold, design: .rounded))
                            .lineLimit(1)
                            .minimumScaleFactor(0.42)
                            .opacity(0.82)
                    } else {
                        Text(String(localized: "No nutrition data"))
                            .font(.system(size: 7.5 * scale, weight: .semibold, design: .rounded))
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                            .opacity(0.76)
                    }
                } else {
                    Text(String(localized: "No meal"))
                        .font(.system(size: 8.5 * scale, weight: .bold, design: .rounded))
                        .foregroundStyle(secondary.opacity(0.72))
                        .lineLimit(1)
                        .minimumScaleFactor(0.55)
                }
            }
            .foregroundStyle(contentColor)
            .padding(6 * scale)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8 * scale, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8 * scale, style: .continuous)
                .stroke(primary.opacity(0.18), lineWidth: max(0.75, scale))
        }
    }

    @ViewBuilder
    private var background: some View {
        if let data = meal?.imageData, let image = Image(data: data) {
            image
                .resizable()
                .scaledToFill()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
        } else {
            let tint = DishGlyph.tint(forName: meal?.name ?? "")
            ZStack {
                Rectangle().fill(day == nil ? primary.opacity(0.07) : tint.opacity(0.78))
                placeholderGlyph
                    .opacity(day == nil ? 0.14 : 0.55)
            }
        }
    }

    @ViewBuilder
    private var placeholderGlyph: some View {
        if let emoji = meal?.glyph?.emoji {
            Text(emoji)
                .font(.system(size: 52 * scale))
        } else {
            Image(systemName: meal?.glyph?.symbolName ?? "fork.knife")
                .font(.system(size: 46 * scale, weight: .bold))
                .foregroundStyle(day == nil ? primary : .white)
        }
    }

    private func energy(_ facts: NutritionFacts) -> String {
        "\(Int(facts.energy(in: energyUnit).rounded()).formatted()) \(energyUnit.symbol)"
    }

    private func macros(_ facts: NutritionFacts) -> String {
        let protein = Int(facts.proteinGrams.rounded())
        let carbs = Int(facts.carbGrams.rounded())
        let fat = Int(facts.fatGrams.rounded())
        return "P \(protein) · C \(carbs) · F \(fat) g"
    }
}

private struct MealNutritionChart: View {
    let points: [MealShareNutritionPoint]
    let energyUnit: EnergyUnit
    let primary: Color
    let accent: Color
    let scale: CGFloat

    private var maximum: Double {
        max(points.map { $0.facts.energy(in: energyUnit) }.max() ?? 0, 1)
    }

    var body: some View {
        GeometryReader { geometry in
            let chartHeight = geometry.size.height - 50 * scale
            let step = geometry.size.width / CGFloat(max(points.count, 1))
            ZStack(alignment: .bottomLeading) {
                VStack {
                    ForEach(0..<4, id: \.self) { _ in
                        Divider().overlay(primary.opacity(0.16))
                        Spacer()
                    }
                    Divider().overlay(primary.opacity(0.16))
                }
                .padding(.bottom, 42 * scale)

                HStack(alignment: .bottom, spacing: 0) {
                    ForEach(Array(points.enumerated()), id: \.element.id) { index, point in
                        let value = point.facts.energy(in: energyUnit)
                        VStack(spacing: 7 * scale) {
                            Spacer(minLength: 0)
                            RoundedRectangle(cornerRadius: min(8 * scale, step * 0.2), style: .continuous)
                                .fill(value > 0 ? accent : primary.opacity(0.12))
                                .frame(
                                    width: max(3, step * 0.62),
                                    height: value > 0 ? max(5, chartHeight * value / maximum) : 3
                                )
                            if shouldLabel(index) {
                                Text(label(for: point.date))
                                    .font(.system(size: 15 * scale, weight: .semibold, design: .rounded))
                                    .foregroundStyle(primary.opacity(0.65))
                                    .lineLimit(1)
                            } else {
                                Text(" ").font(.system(size: 15 * scale))
                            }
                        }
                        .frame(width: step)
                    }
                }
            }
        }
    }

    private func shouldLabel(_ index: Int) -> Bool {
        let stride = switch points.count {
        case ...8: 1
        case ...16: 2
        default: 5
        }
        return index.isMultiple(of: stride)
    }

    private func label(for date: Date) -> String {
        if points.count == 12 { return date.formatted(.dateTime.month(.narrow)) }
        if points.count <= 8 { return date.formatted(.dateTime.weekday(.narrow)) }
        return date.formatted(.dateTime.day())
    }
}

private struct MealShareBackgroundView: View {
    let background: MealShareBackground

    var body: some View {
        ZStack {
            switch background {
            case .cookbook:
                LinearGradient(
                    colors: [Color(red: 0.23, green: 0.07, blue: 0.12), Color(red: 0.62, green: 0.17, blue: 0.18), .orange.opacity(0.88)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                decorativeCircles(color: .pink)
            case .citrus:
                LinearGradient(
                    colors: [Color(red: 1, green: 0.96, blue: 0.72), Color(red: 1, green: 0.69, blue: 0.27)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                decorativeCircles(color: .white)
            case .garden:
                LinearGradient(
                    colors: [Color(red: 0.04, green: 0.18, blue: 0.16), Color(red: 0.08, green: 0.42, blue: 0.28), .teal.opacity(0.82)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                decorativeCircles(color: .mint)
            case .midnight:
                LinearGradient(colors: [.black, Color(red: 0.10, green: 0.10, blue: 0.27), .indigo], startPoint: .top, endPoint: .bottomTrailing)
                decorativeCircles(color: .purple)
            case .paper:
                Color(red: 0.96, green: 0.93, blue: 0.85)
                VStack(spacing: 28) {
                    ForEach(0..<40, id: \.self) { _ in
                        Rectangle().fill(Color.blue.opacity(0.08)).frame(height: 1)
                    }
                }
            }
        }
    }

    private func decorativeCircles(color: Color) -> some View {
        GeometryReader { geometry in
            ZStack {
                Circle()
                    .fill(color.opacity(0.16))
                    .frame(width: geometry.size.width * 0.76)
                    .offset(x: geometry.size.width * 0.55, y: -geometry.size.height * 0.16)
                Circle()
                    .stroke(color.opacity(0.17), lineWidth: geometry.size.width * 0.06)
                    .frame(width: geometry.size.width * 0.64)
                    .offset(x: -geometry.size.width * 0.28, y: geometry.size.height * 0.69)
            }
        }
    }
}

#Preview {
    NavigationStack { MealShareGalleryView() }
        .environment(AppState.preview)
        .modelContainer(PreviewData.container)
}
