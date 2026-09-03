import AppIntents
import CoreSpotlight
import OSLog
import SwiftData

// MARK: - Shared intent store

/// App Intents may run outside the app's normal SwiftUI scene, so they open
/// the same App Group store without starting a second CloudKit mirror.
@MainActor
enum MealPlanIntentStore {
    static let container = SharedStore.container(cloudKit: false)
    static var context: ModelContext { container.mainContext }

    static func household() -> Household? {
        try? context.fetch(FetchDescriptor<Household>()).first
    }

    static func mealTypes() -> [MealType] {
        let meals = (try? context.fetch(FetchDescriptor<MealType>(
            sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.name)]
        ))) ?? []
        if meals.isEmpty, let household = household() {
            MealType.ensure(for: household, context: context)
            return (try? context.fetch(FetchDescriptor<MealType>(
                sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.name)]
            ))) ?? []
        }
        return meals
    }

    static func entity(for entry: MealPlanEntry) -> MealPlanEntryEntity {
        let meals = Dictionary(uniqueKeysWithValues: mealTypes().map { ($0.key, $0) })
        return MealPlanEntryEntity(entry: entry, meal: meals[entry.mealKey])
    }
}

// MARK: - Meal type

/// A user-configurable meal such as Breakfast, Dinner, or Afternoon Tea.
struct MealTypeEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Meal" }
    static var defaultQuery: MealTypeEntityQuery { MealTypeEntityQuery() }

    let id: String
    @Property(title: "Name") var name: String

    init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    init(meal: MealType) {
        id = meal.key
        name = meal.name
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", image: .init(systemName: "fork.knife"))
    }
}

struct MealTypeEntityQuery: EnumerableEntityQuery, EntityStringQuery {
    @MainActor
    func allEntities() async throws -> [MealTypeEntity] {
        MealPlanIntentStore.mealTypes().map(MealTypeEntity.init)
    }

    @MainActor
    func entities(for identifiers: [String]) async throws -> [MealTypeEntity] {
        MealPlanIntentStore.mealTypes()
            .filter { identifiers.contains($0.key) }
            .map(MealTypeEntity.init)
    }

    @MainActor
    func suggestedEntities() async throws -> [MealTypeEntity] {
        MealPlanIntentStore.mealTypes().map(MealTypeEntity.init)
    }

    @MainActor
    func entities(matching string: String) async throws -> [MealTypeEntity] {
        MealPlanIntentStore.mealTypes()
            .filter {
                $0.name.localizedCaseInsensitiveContains(string)
                    || $0.key.localizedCaseInsensitiveContains(string)
            }
            .map(MealTypeEntity.init)
    }
}

// MARK: - Calendar App Schema entities (iOS 27)

/// The household's meal plan is exposed as one calendar to Siri.
@AppEntity(schema: .calendar.calendar)
struct MealPlanCalendarEntity: IndexedEntity {
    static let defaultQuery = CalendarQuery()

    let id: UUID
    var title: String

    init(household: Household) {
        id = household.uuid
        title = household.name.isEmpty ? String(localized: "Meal Plan") : household.name
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", image: .init(systemName: "calendar"))
    }

    @MainActor
    struct CalendarQuery: EnumerableEntityQuery, EntityStringQuery, IndexedEntityQuery {
        func allEntities() async throws -> [MealPlanCalendarEntity] {
            let households = try MealPlanIntentStore.context.fetch(FetchDescriptor<Household>())
            return households.map(MealPlanCalendarEntity.init)
        }

        func entities(for identifiers: [UUID]) async throws -> [MealPlanCalendarEntity] {
            try await allEntities().filter { identifiers.contains($0.id) }
        }

        func suggestedEntities() async throws -> [MealPlanCalendarEntity] {
            try await allEntities()
        }

        func entities(matching string: String) async throws -> [MealPlanCalendarEntity] {
            try await allEntities().filter { $0.title.localizedCaseInsensitiveContains(string) }
        }

        nonisolated func reindexEntities(
            for identifiers: [MealPlanCalendarEntity.ID],
            indexDescription: CSSearchableIndexDescription
        ) async throws {
            let entities = try await entities(for: identifiers)
            try await MealPlanSpotlightIndexer.indexEntities(entities)
        }

        nonisolated func reindexAllEntities(indexDescription: CSSearchableIndexDescription) async throws {
            let entities = try await allEntities()
            try await MealPlanSpotlightIndexer.indexEntities(entities)
        }
    }
}

@AppEntity(schema: .calendar.attendee)
struct MealPlanAttendeeEntity: TransientAppEntity {
    var person: IntentPerson
    var status: MealPlanParticipantStatus?
    var isAttendanceOptional: Bool
    var type: MealPlanAttendeeType?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "Household member", image: .init(systemName: "person"))
    }

    init() { }
}

@AppEnum(schema: .calendar.attendeeStatus)
enum MealPlanParticipantStatus: String {
    case accepted, declined, tentative

    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .accepted: "Accepted",
        .declined: "Declined",
        .tentative: "Tentative",
    ]
}

@AppEnum(schema: .calendar.attendeeType)
enum MealPlanAttendeeType: String {
    case person
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [.person: "Person"]
}

@AppEnum(schema: .calendar.eventStatus)
enum MealPlanEventStatus: String {
    case confirmed, tentative, cancelled

    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .confirmed: "Confirmed",
        .tentative: "Tentative",
        .cancelled: "Cancelled",
    ]
}

@AppEnum(schema: .calendar.eventSpan)
enum MealPlanEventSpan: String {
    case this, future, all

    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .this: "This meal",
        .future: "This and future meals",
        .all: "All meals",
    ]
}

@UnionValue
enum MealPlanEventLocation {
    case address(String)
}

@UnionValue
enum MealPlanEventAlarm {
    case duration(Duration)
    case date(Date)
}

/// One planned meal, represented as a calendar event so iOS 27 Siri can
/// search it semantically and answer questions about the existing plan.
@AppEntity(schema: .calendar.event)
struct MealPlanEntryEntity: IndexedEntity {
    static let defaultQuery = EntryQuery()

    var id: UUID
    var calendar: MealPlanCalendarEntity

    @Property(indexingKey: \.title)
    var title: String

    var startDate: Date
    var endDate: Date
    var isAllDay: Bool
    var recurrence: Calendar.RecurrenceRule?

    @Property(indexingKey: \.textContent)
    var note: AttributedString?

    var travelTime: Duration?
    var location: MealPlanEventLocation?
    var virtualLocation: URL?
    var status: MealPlanEventStatus?
    var alarms: [MealPlanEventAlarm]
    var organizers: [IntentPerson]
    var attendees: [MealPlanAttendeeEntity]
    var isFavorite: Bool

    /// MealPlan-specific properties remain available to Shortcuts and Siri's
    /// content answers in addition to the standard Calendar schema fields.
    @Property(title: "Meal") var mealName: String
    @Property(title: "Servings") var servings: Int

    @MainActor
    init(entry: MealPlanEntry, meal: MealType?) {
        id = entry.uuid
        isFavorite = entry.dish?.isFavorite ?? false
        let household = entry.household ?? MealPlanIntentStore.household() ?? Household(name: "MealPlan")
        calendar = MealPlanCalendarEntity(household: household)
        title = entry.displayTitle
        mealName = meal?.name ?? MealType.legacyName(for: entry.mealKey)
        servings = entry.effectiveServings
        startDate = Self.date(for: entry.date, mealKey: entry.mealKey, sortOrder: meal?.sortOrder)
        endDate = startDate.addingTimeInterval(60 * 60)
        isAllDay = false
        recurrence = nil

        let details = [
            mealName,
            String(localized: "Serves \(servings)"),
            entry.note,
            entry.isEatingOut ? entry.placeName : nil,
        ].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ". ")
        note = details.isEmpty ? nil : AttributedString(details)

        travelTime = nil
        location = entry.placeAddress.map(MealPlanEventLocation.address)
        virtualLocation = nil
        status = entry.skipped ? .cancelled : .confirmed
        alarms = []
        organizers = []
        attendees = []
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)",
            subtitle: "\(mealName) · \(startDate.formatted(date: .abbreviated, time: .omitted))",
            image: .init(systemName: "fork.knife.circle")
        )
    }

    private static func date(for day: Date, mealKey: String, sortOrder: Int?) -> Date {
        let hour: Int = switch mealKey {
        case "breakfast": 8
        case "lunch": 12
        case "snack": 15
        case "dinner": 18
        default: min(21, 8 + max(0, sortOrder ?? 2) * 3)
        }
        return Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: day) ?? day
    }

    @MainActor
    struct EntryQuery: EnumerableEntityQuery, EntityStringQuery, IndexedEntityQuery {
        func allEntities() async throws -> [MealPlanEntryEntity] {
            let entries = try MealPlanIntentStore.context.fetch(FetchDescriptor<MealPlanEntry>(
                predicate: #Predicate { $0.skipped == false },
                sortBy: [SortDescriptor(\.date), SortDescriptor(\.sortIndex)]
            ))
            let meals = Dictionary(uniqueKeysWithValues: MealPlanIntentStore.mealTypes().map { ($0.key, $0) })
            return entries.map { MealPlanEntryEntity(entry: $0, meal: meals[$0.mealKey]) }
        }

        func entities(for identifiers: [UUID]) async throws -> [MealPlanEntryEntity] {
            try await allEntities().filter { identifiers.contains($0.id) }
        }

        func suggestedEntities() async throws -> [MealPlanEntryEntity] {
            let today = Date.now.startOfDay
            return try await allEntities().filter { $0.startDate >= today }.prefix(20).map { $0 }
        }

        func entities(matching string: String) async throws -> [MealPlanEntryEntity] {
            try await allEntities().filter {
                $0.title.localizedCaseInsensitiveContains(string)
                    || $0.mealName.localizedCaseInsensitiveContains(string)
                    || String($0.note?.characters ?? AttributedString().characters)
                        .localizedCaseInsensitiveContains(string)
            }
        }

        nonisolated func reindexEntities(
            for identifiers: [MealPlanEntryEntity.ID],
            indexDescription: CSSearchableIndexDescription
        ) async throws {
            let entities = try await entities(for: identifiers)
            try await MealPlanSpotlightIndexer.indexEntities(entities)
        }

        nonisolated func reindexAllEntities(indexDescription: CSSearchableIndexDescription) async throws {
            let entities = try await allEntities()
            try await MealPlanSpotlightIndexer.indexEntities(entities)
        }
    }
}

// MARK: - Spotlight donation

@MainActor
enum MealPlanSpotlightIndexer {
    private nonisolated static let indexName = "de.holgerkrupp.mealplan.entities"
    private static var pendingTask: Task<Void, Never>?

    nonisolated static func indexEntities<Entity: IndexedEntity>(_ entities: [Entity]) async throws {
        let searchableIndex = CSSearchableIndex(name: indexName)
        try await searchableIndex.indexAppEntities(entities)
    }

    nonisolated static func deleteAll() async throws {
        let searchableIndex = CSSearchableIndex(name: indexName)
        try await searchableIndex.deleteAllSearchableItems()
    }

    static func scheduleReindex(context: ModelContext) {
        pendingTask?.cancel()
        pendingTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await reindexAll(context: context)
        }
    }

    static func reindexAll(context: ModelContext) async {
        do {
            let dishes = try context.fetch(FetchDescriptor<Dish>(sortBy: [SortDescriptor(\.name)]))
                .map(DishEntity.init)
            let mealTypes = try context.fetch(FetchDescriptor<MealType>())
            let mealsByKey = Dictionary(uniqueKeysWithValues: mealTypes.map { ($0.key, $0) })
            let entries = try context.fetch(FetchDescriptor<MealPlanEntry>(
                predicate: #Predicate { $0.skipped == false },
                sortBy: [SortDescriptor(\.date), SortDescriptor(\.sortIndex)]
            )).map { MealPlanEntryEntity(entry: $0, meal: mealsByKey[$0.mealKey]) }
            let calendars = try context.fetch(FetchDescriptor<Household>())
                .map(MealPlanCalendarEntity.init)

            try await deleteAll()
            try await indexEntities(dishes)
            try await indexEntities(entries)
            try await indexEntities(calendars)
        } catch {
            SharedStore.logger.error("Could not update the App Intents search index: \(error.localizedDescription)")
        }
    }
}
