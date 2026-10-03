import AppIntents
import CoreSpotlight
import Foundation
import SwiftData

// The Calendar schema is available in the iOS 27 SDK but the app still ships
// with an iOS 26 deployment target. These types are availability-gated and
// deliberately have their own names, so the generic MealPlanEntryEntity keeps
// working on older systems.

@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
@AppEntity(schema: .calendar.calendar)
struct MealPlanCalendarSchemaEntity: IndexedEntity {
    static let defaultQuery = Query()
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
    struct Query: EnumerableEntityQuery, EntityStringQuery, IndexedEntityQuery {
        func allEntities() async throws -> [MealPlanCalendarSchemaEntity] {
            try MealPlanIntentStore.context.fetch(FetchDescriptor<Household>()).map(MealPlanCalendarSchemaEntity.init)
        }

        func entities(for identifiers: [UUID]) async throws -> [MealPlanCalendarSchemaEntity] {
            try await allEntities().filter { identifiers.contains($0.id) }
        }

        func suggestedEntities() async throws -> [MealPlanCalendarSchemaEntity] { try await allEntities() }

        func entities(matching string: String) async throws -> [MealPlanCalendarSchemaEntity] {
            try await allEntities().filter { $0.title.localizedCaseInsensitiveContains(string) }
        }

        nonisolated func reindexEntities(
            for identifiers: [MealPlanCalendarSchemaEntity.ID],
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

@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
@AppEnum(schema: .calendar.eventStatus)
enum MealPlanCalendarSchemaEventStatus: String {
    case confirmed, tentative, cancelled
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .confirmed: "Confirmed", .tentative: "Tentative", .cancelled: "Cancelled",
    ]
}

@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
@AppEnum(schema: .calendar.eventSpan)
enum MealPlanCalendarSchemaEventSpan: String {
    case this, future, all
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .this: "This meal", .future: "This and future meals", .all: "All meals",
    ]
}

@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
@UnionValue
enum MealPlanCalendarSchemaLocation { case address(String) }

@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
@UnionValue
enum MealPlanCalendarSchemaAlarm { case duration(Duration); case date(Date) }

@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
@AppEnum(schema: .calendar.attendeeStatus)
enum MealPlanCalendarSchemaAttendeeStatus: String {
    case accepted, declined, tentative
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .accepted: "Accepted", .declined: "Declined", .tentative: "Tentative",
    ]
}

@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
@AppEnum(schema: .calendar.attendeeType)
enum MealPlanCalendarSchemaAttendeeType: String {
    case person, group, resource
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .person: "Person", .group: "Group", .resource: "Resource",
    ]
}

@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
@AppEntity(schema: .calendar.attendee)
struct MealPlanCalendarSchemaAttendeeEntity {
    static let defaultQuery = AttendeeQuery()

    let id: UUID
    var person: IntentPerson
    var status: MealPlanCalendarSchemaAttendeeStatus?
    var isAttendanceOptional: Bool
    var type: MealPlanCalendarSchemaAttendeeType?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(String(describing: person.name))")
    }

    init(id: UUID = UUID(), person: IntentPerson) {
        self.id = id
        self.person = person
        status = nil
        isAttendanceOptional = false
        type = .person
    }

    struct AttendeeQuery: EntityQuery, EntityStringQuery {
        func entities(for identifiers: [UUID]) async throws -> [MealPlanCalendarSchemaAttendeeEntity] { [] }
        func entities(matching string: String) async throws -> [MealPlanCalendarSchemaAttendeeEntity] { [] }
    }
}

@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
@AppEntity(schema: .calendar.event)
struct MealPlanCalendarEventSchemaEntity: IndexedEntity {
    static let defaultQuery = EventQuery()

    let id: UUID
    var calendar: MealPlanCalendarSchemaEntity
    @Property(indexingKey: \.title) var title: String
    var startDate: Date
    var endDate: Date
    var isAllDay: Bool
    var recurrence: Calendar.RecurrenceRule?
    @Property(indexingKey: \.textContent) var note: AttributedString?
    var travelTime: Duration?
    var location: MealPlanCalendarSchemaLocation?
    var virtualLocation: URL?
    var status: MealPlanCalendarSchemaEventStatus?
    var alarms: [MealPlanCalendarSchemaAlarm]
    var organizers: [IntentPerson]
    var attendees: [MealPlanCalendarSchemaAttendeeEntity]
    var isFavorite: Bool
    @Property(title: "Meal") var mealName: String
    @Property(title: "Servings") var servings: Int

    @MainActor
    init(entry: MealPlanEntry, meal: MealType?) {
        id = entry.uuid
        isFavorite = entry.dish?.isFavorite ?? false
        let household = entry.household ?? MealPlanIntentStore.household() ?? Household(name: "MealPlan")
        calendar = MealPlanCalendarSchemaEntity(household: household)
        title = entry.displayTitle
        mealName = meal?.name ?? MealType.legacyName(for: entry.mealKey)
        servings = entry.effectiveServings
        startDate = Self.date(for: entry.date, mealKey: entry.mealKey, sortOrder: meal?.sortOrder)
        endDate = startDate.addingTimeInterval(3600)
        isAllDay = false
        recurrence = nil
        let details = [mealName, String(localized: "Serves \(servings)"), entry.note]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ". ")
        note = details.isEmpty ? nil : AttributedString(details)
        travelTime = nil
        location = entry.placeAddress.map(MealPlanCalendarSchemaLocation.address)
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
    struct EventQuery: EnumerableEntityQuery, EntityStringQuery, IndexedEntityQuery {
        func allEntities() async throws -> [MealPlanCalendarEventSchemaEntity] {
            let entries = try MealPlanIntentStore.context.fetch(FetchDescriptor<MealPlanEntry>(
                predicate: #Predicate { $0.skipped == false },
                sortBy: [SortDescriptor(\.date), SortDescriptor(\.sortIndex)]
            ))
            let meals = Dictionary(uniqueKeysWithValues: MealPlanIntentStore.mealTypes().map { ($0.key, $0) })
            return entries.map { MealPlanCalendarEventSchemaEntity(entry: $0, meal: meals[$0.mealKey]) }
        }

        func entities(for identifiers: [UUID]) async throws -> [MealPlanCalendarEventSchemaEntity] {
            try await allEntities().filter { identifiers.contains($0.id) }
        }

        func suggestedEntities() async throws -> [MealPlanCalendarEventSchemaEntity] {
            try await allEntities().filter { $0.startDate >= .now }.prefix(20).map { $0 }
        }

        func entities(matching string: String) async throws -> [MealPlanCalendarEventSchemaEntity] {
            try await allEntities().filter { $0.title.localizedCaseInsensitiveContains(string) || $0.mealName.localizedCaseInsensitiveContains(string) }
        }

        nonisolated func reindexEntities(
            for identifiers: [MealPlanCalendarEventSchemaEntity.ID],
            indexDescription: CSSearchableIndexDescription
        ) async throws {
            try await MealPlanSpotlightIndexer.indexEntities(entities(for: identifiers))
        }

        nonisolated func reindexAllEntities(indexDescription: CSSearchableIndexDescription) async throws {
            try await MealPlanSpotlightIndexer.indexEntities(allEntities())
        }
    }
}

@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
enum MealPlanCalendarSchemaSupport {
    @MainActor
    static func entry(for entity: MealPlanCalendarEventSchemaEntity) throws -> MealPlanEntry {
        let id = entity.id
        guard let entry = try MealPlanIntentStore.context.fetch(FetchDescriptor<MealPlanEntry>(predicate: #Predicate { $0.uuid == id })).first else {
            throw NSError(domain: "MealPlan.AppIntents", code: 40, userInfo: [NSLocalizedDescriptionKey: String(localized: "That planned meal no longer exists.")])
        }
        return entry
    }

    @MainActor
    static func result(for entry: MealPlanEntry) -> MealPlanCalendarEventSchemaEntity {
        MealPlanCalendarEventSchemaEntity(entry: entry, meal: MealPlanIntentStore.mealTypes().first { $0.key == entry.mealKey })
    }
}

@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
@AppIntent(schema: .calendar.createEvent)
struct CreatePlannedMealIntent {
    var title: String
    var startDate: Date
    var endDate: Date?
    var location: MealPlanCalendarSchemaLocation?
    var calendar: MealPlanCalendarSchemaEntity
    var isAllDay: Bool
    var recurrence: Calendar.RecurrenceRule?
    var attendees: [MealPlanCalendarSchemaAttendeeEntity]
    var note: AttributedString?

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<MealPlanCalendarEventSchemaEntity> {
        try MealPlanIntentResolver.requireEditingAllowed()
        try await MealPlanIntentResolver.requirePlanningAllowed(on: startDate)
        let household = try MealPlanWorkflowIntentSupport.activeHousehold()
        let meals = MealPlanIntentStore.mealTypes()
        let text = title + " " + (note.map { String($0.characters) } ?? "")
        guard let meal = MealPlanIntentResolver.meal(mentionedIn: text, at: startDate, available: meals) else {
            throw NSError(domain: "MealPlan.AppIntents", code: 41, userInfo: [NSLocalizedDescriptionKey: String(localized: "No meals are configured in MealPlan.")])
        }
        let dish = try MealPlanIntentResolver.dish(named: MealPlanIntentResolver.cleanDishName(title, meal: meal), household: household)
        let entry = MealPlanner.plan(dish: dish, on: startDate, mealKey: meal.key, note: note.map { String($0.characters) }, household: household, memberName: MealPlanIntentStore.currentMemberName, context: MealPlanIntentStore.context)
        if let recurrence, recurrence.frequency == .weekly {
            let routine = MealRoutine(dish: dish, mealKey: meal.key, weekday: Calendar.current.component(.weekday, from: startDate), intervalWeeks: recurrence.interval, startDate: startDate)
            routine.household = household
            MealPlanIntentStore.context.insert(routine)
            MealRoutineScheduler.apply(routine, household: household, context: MealPlanIntentStore.context, through: PurchaseManager.shared.latestPlanningDate(), memberName: MealPlanIntentStore.currentMemberName)
        }
        await MealPlanIntentResolver.index(entry)
        return .result(value: MealPlanCalendarSchemaSupport.result(for: entry))
    }
}

@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
@AppIntent(schema: .calendar.updateEvent)
struct UpdatePlannedMealIntent {
    var event: MealPlanCalendarEventSchemaEntity
    var title: String?
    var attendees: [MealPlanCalendarSchemaAttendeeEntity]?
    var startDate: Date?
    var endDate: Date?
    var isAllDay: Bool?
    var calendar: MealPlanCalendarSchemaEntity?
    var recurrence: Calendar.RecurrenceRule?
    var note: String?
    var location: MealPlanCalendarSchemaLocation?
    var span: MealPlanCalendarSchemaEventSpan?

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<MealPlanCalendarEventSchemaEntity> {
        try MealPlanIntentResolver.requireEditingAllowed()
        let entry = try MealPlanCalendarSchemaSupport.entry(for: event)
        let effectiveDate = startDate ?? entry.date
        if startDate != nil { try await MealPlanIntentResolver.requirePlanningAllowed(on: effectiveDate) }
        if let title {
            let meal = MealPlanIntentResolver.meal(mentionedIn: title + " " + (note ?? ""), at: effectiveDate, available: MealPlanIntentStore.mealTypes())
            entry.dish = try MealPlanIntentResolver.dish(named: MealPlanIntentResolver.cleanDishName(title, meal: meal), household: entry.household)
            entry.isEatingOut = false
            if let meal, meal.key != entry.mealKey { entry.mealKey = meal.key }
        }
        if startDate != nil { MealPlanner.move(entry, to: effectiveDate, mealKey: entry.mealKey, memberName: MealPlanIntentStore.currentMemberName, context: MealPlanIntentStore.context) }
        if let note { entry.note = note }
        if case .address(let address) = location { entry.placeAddress = address }
        entry.lastEditedByName = MealPlanIntentStore.currentMemberName
        entry.lastEditedDate = .now
        try MealPlanIntentStore.context.save()
        SharedStore.reloadWidgets()
        await MealPlanIntentResolver.index(entry)
        return .result(value: MealPlanCalendarSchemaSupport.result(for: entry))
    }
}

@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
@AppIntent(schema: .calendar.deleteEvent)
struct DeletePlannedMealIntent {
    var entity: MealPlanCalendarEventSchemaEntity
    var span: MealPlanCalendarSchemaEventSpan?

    @MainActor
    func perform() async throws -> some IntentResult {
        try MealPlanIntentResolver.requireEditingAllowed()
        let selected = try MealPlanCalendarSchemaSupport.entry(for: entity)
        if let routineID = selected.routineUUID, span != .this {
            let selectedDate = selected.date
            let all = try MealPlanIntentStore.context.fetch(FetchDescriptor<MealPlanEntry>(predicate: #Predicate { $0.routineUUID == routineID }))
            for entry in all where span == .all || entry.date >= selectedDate { MealPlanIntentStore.context.delete(entry) }
        } else {
            MealPlanIntentStore.context.delete(selected)
        }
        try MealPlanIntentStore.context.save()
        SharedStore.reloadWidgets()
        MealPlanSpotlightIndexer.scheduleReindex(context: MealPlanIntentStore.context)
        return .result()
    }
}
