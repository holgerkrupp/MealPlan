@preconcurrency import CloudKit
@preconcurrency import CoreData
import CollaborationCore
import CollaborationCoreData
import CollaborationDiagnostics
import CollaborationUI
import Foundation

/// Immutable household information needed by the sharing screens. Keeping
/// this projection separate from the legacy SwiftData model lets the native
/// sharing UI read its title and reinvitation checklist from the store it
/// actually shares.
struct ManagedHouseholdMemberSummary: Identifiable, Equatable, Sendable {
    let id: UUID
    let name: String
    let isActive: Bool
    let isCurrentUser: Bool
    let roleRaw: String
    let dateAdded: Date
    var allergies: [String]
    var mustAvoidIngredients: [String]
    var dietaryPatterns: [String]
    var dislikes: [String]
    var favorites: [String]
    var preferredCuisines: [String]
    var spiceTolerance: Int?
}

struct ManagedHouseholdSummary: Equatable, Sendable {
    let id: UUID
    let name: String
    let standardServings: Int
    let members: [ManagedHouseholdMemberSummary]
}

struct ManagedPantryIngredientSummary: Identifiable, Equatable, Sendable {
    let id: UUID
    let name: String
    let normalizedName: String
    let categoryRaw: String
    let customAisleName: String?
    let isPantryStaple: Bool
    let aliases: [IngredientMatchAliasValue]
    let rejectedMatchKeys: [String]

    var category: IngredientCategory { IngredientCategory(rawValue: categoryRaw) ?? .other }
    var aisleName: String {
        let custom = customAisleName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return custom.isEmpty ? category.localizedName : custom
    }
    var matchValue: IngredientMatchCandidateValue {
        IngredientMatchCandidateValue(
            id: id,
            name: name,
            normalizedName: normalizedName,
            aliases: aliases,
            rejectedMatchKeys: rejectedMatchKeys
        )
    }
}

struct ManagedPantrySnapshot: Equatable, Sendable {
    let householdID: UUID
    let ingredients: [ManagedPantryIngredientSummary]
    let shoppingItemKeys: Set<String>
    let matchRules: [IngredientMatchRuleValue]
}

struct ManagedShoppingListItemSummary: Identifiable, Equatable, Sendable {
    let id: UUID
    let name: String
    let displayText: String?
    let sourceDishNames: [String]
    let isChecked: Bool
    let isManual: Bool
    let isStaple: Bool
    let categoryRaw: String
    let customAisleName: String?
    let sortIndex: Int
    let rangeStart: Date?
    let rangeEnd: Date?

    var category: IngredientCategory { IngredientCategory(rawValue: categoryRaw) ?? .other }
    var aisleName: String {
        let custom = customAisleName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return custom.isEmpty ? category.localizedName : custom
    }
}

struct ManagedShoppingListSnapshot: Equatable, Sendable {
    let householdID: UUID
    let items: [ManagedShoppingListItemSummary]
    let pantryStaples: [ManagedPantryIngredientSummary]
    let missingIngredientDishNames: [String]
}

struct ManagedDishChoice: Identifiable, Equatable, Sendable {
    let id: UUID
    let name: String
}

struct ManagedMealTypeChoice: Identifiable, Equatable, Sendable {
    let id: UUID
    let key: String
    let name: String
    let symbolName: String
    let sortOrder: Int
}

struct ManagedMealRoutineSummary: Identifiable, Equatable, Sendable {
    let id: UUID
    let dishID: UUID?
    let dishName: String?
    let mealKey: String
    let weekday: Int
    let intervalWeeks: Int
    let startDate: Date
    let isActive: Bool
    let plannedThrough: Date?
    let dateCreated: Date

    var scheduleDescription: String {
        let symbols = Calendar.current.standaloneWeekdaySymbols
        let index = min(max(weekday - 1, 0), symbols.count - 1)
        let dayName = symbols[index]
        return switch max(1, intervalWeeks) {
        case 1: String(localized: "Every \(dayName)")
        case 2: String(localized: "Every second \(dayName)")
        case 3: String(localized: "Every third \(dayName)")
        case 4: String(localized: "Every fourth \(dayName)")
        default: String(localized: "Every \(intervalWeeks) weeks on \(dayName)")
        }
    }
}

struct ManagedMealRoutineDraft: Identifiable, Equatable, Sendable {
    let id: UUID
    var dishID: UUID?
    var mealKey: String
    var weekday: Int
    var intervalWeeks: Int
    var startDate: Date
    var isActive: Bool
}

struct ManagedMealRoutineSnapshot: Equatable, Sendable {
    let householdID: UUID
    let routines: [ManagedMealRoutineSummary]
    let dishes: [ManagedDishChoice]
    let mealTypes: [ManagedMealTypeChoice]
}

/// MealPlan's host adapter for the reusable collaboration package. Construction
/// is deliberately explicit: callers must load a CloudKit-enabled managed
/// persistence instance first, and share creation remains an explicit user action.
@MainActor
final class MealPlanManagedCollaboration {
    let sharing: ManagedSharingService
    let invitations: InvitationAcceptanceCoordinator
    let eventMonitor: ManagedContainerEventMonitor
    let container: NSPersistentCloudKitContainer
    let cloudKitContainer: CKContainer
    let privateStore: NSPersistentStore
    let sharedStore: NSPersistentStore
    private let graphPreflight: MealPlanShareGraphPreflight

    init(persistence: ManagedHouseholdPersistence) throws {
        guard persistence.isLoaded, persistence.cloudKitEnabled else {
            throw MealPlanManagedCollaborationError.managedStoresUnavailable
        }
        container = persistence.container
        privateStore = try persistence.persistentStore(for: .private)
        sharedStore = try persistence.persistentStore(for: .shared)
        cloudKitContainer = CKContainer(identifier: SharedStore.cloudKitContainerID)

        let configuration = CollaborationConfiguration(
            containerIdentifier: SharedStore.cloudKitContainerID,
            environment: Self.packageEnvironment(BuildEnvironment.cloudKit)
        )
        let resolver = MealPlanShareRootResolver(
            context: persistence.container.viewContext,
            privateStore: privateStore
        )
        let graphPreflight = try MealPlanShareGraphPreflight(
            container: persistence.container,
            privateStore: privateStore
        )
        self.graphPreflight = graphPreflight
        sharing = try ManagedSharingService(
            configuration: configuration,
            container: persistence.container,
            privateStore: privateStore,
            sharedStore: sharedStore,
            rootResolver: resolver,
            preflight: graphPreflight
        )
        invitations = InvitationAcceptanceCoordinator(
            containerIdentifier: configuration.containerIdentifier
        ) { [sharing] metadata in
            try await sharing.accept(metadata)
        }
        eventMonitor = ManagedContainerEventMonitor(container: persistence.container) { event in
            NotificationCenter.default.post(
                name: .mealPlanManagedCollaborationEvent,
                object: event
            )
        }
    }

    func householdSummary(for householdID: UUID) throws -> ManagedHouseholdSummary {
        let objectID = try managedHouseholdObjectID(for: householdID)
        let root = try container.viewContext.existingObject(with: objectID)
        guard root.value(forKey: "managedMigrationPhaseRaw") as? String == "verified",
              let name = root.value(forKey: "name") as? String else {
            throw MealPlanManagedCollaborationError.householdNotFound
        }
        let standardServings = max(1, (root.value(forKey: "standardServings") as? NSNumber)?.intValue ?? 2)

        let records = (root.value(forKey: "members") as? NSSet)?.allObjects.compactMap { $0 as? NSManagedObject } ?? []
        let members = records.compactMap { member -> ManagedHouseholdMemberSummary? in
            guard let id = member.value(forKey: "uuid") as? UUID,
                  let name = member.value(forKey: "name") as? String else { return nil }
            return ManagedHouseholdMemberSummary(
                id: id,
                name: name,
                isActive: (member.value(forKey: "isActive") as? NSNumber)?.boolValue ?? false,
                isCurrentUser: (member.value(forKey: "isCurrentUser") as? NSNumber)?.boolValue ?? false,
                roleRaw: member.value(forKey: "roleRaw") as? String ?? MemberRole.editor.rawValue,
                dateAdded: member.value(forKey: "dateAdded") as? Date ?? .distantPast,
                allergies: Self.stringArray(member.value(forKey: "allergies")),
                mustAvoidIngredients: Self.stringArray(member.value(forKey: "mustAvoidIngredients")),
                dietaryPatterns: Self.stringArray(member.value(forKey: "dietaryPatterns")),
                dislikes: Self.stringArray(member.value(forKey: "dislikes")),
                favorites: Self.stringArray(member.value(forKey: "favorites")),
                preferredCuisines: Self.stringArray(member.value(forKey: "preferredCuisines")),
                spiceTolerance: (member.value(forKey: "spiceTolerance") as? NSNumber)?.intValue
            )
        }
        .sorted {
            $0.dateAdded == $1.dateAdded ? $0.id.uuidString < $1.id.uuidString : $0.dateAdded < $1.dateAdded
        }
        return ManagedHouseholdSummary(
            id: householdID,
            name: name,
            standardServings: standardServings,
            members: members
        )
    }

    func pantrySnapshot(for householdID: UUID) throws -> ManagedPantrySnapshot {
        let objectID = try managedHouseholdObjectID(for: householdID)
        let root = try container.viewContext.existingObject(with: objectID)
        let ingredientObjects = (root.value(forKey: "ingredients") as? NSSet)?.allObjects.compactMap { $0 as? NSManagedObject } ?? []
        let ingredients = ingredientObjects.compactMap { ingredient -> ManagedPantryIngredientSummary? in
            guard let id = ingredient.value(forKey: "uuid") as? UUID,
                  let name = ingredient.value(forKey: "name") as? String else { return nil }
            let aliasObjects = (ingredient.value(forKey: "aliases") as? NSSet)?.allObjects.compactMap { $0 as? NSManagedObject } ?? []
            let aliases = aliasObjects.compactMap { alias -> IngredientMatchAliasValue? in
                guard let aliasName = alias.value(forKey: "name") as? String,
                      let normalizedName = alias.value(forKey: "normalizedName") as? String else { return nil }
                return IngredientMatchAliasValue(
                    name: aliasName,
                    normalizedName: normalizedName,
                    sourceRaw: alias.value(forKey: "sourceRaw") as? String ?? IngredientAliasSource.automatic.rawValue
                )
            }
            return ManagedPantryIngredientSummary(
                id: id,
                name: name,
                normalizedName: ingredient.value(forKey: "normalizedName") as? String ?? Ingredient.normalize(name),
                categoryRaw: ingredient.value(forKey: "categoryRaw") as? String ?? IngredientCategory.other.rawValue,
                customAisleName: ingredient.value(forKey: "customAisleName") as? String,
                isPantryStaple: (ingredient.value(forKey: "isPantryStaple") as? NSNumber)?.boolValue ?? false,
                aliases: aliases,
                rejectedMatchKeys: Self.stringArray(ingredient.value(forKey: "rejectedMatchKeys"))
            )
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        let shoppingObjects = (root.value(forKey: "shoppingItems") as? NSSet)?.allObjects.compactMap { $0 as? NSManagedObject } ?? []
        let shoppingItemKeys = Set(shoppingObjects.compactMap { $0.value(forKey: "name") as? String }.map(IngredientMatching.key(for:)))
        let ruleObjects = (root.value(forKey: "matchRules") as? NSSet)?.allObjects.compactMap { $0 as? NSManagedObject } ?? []
        let matchRules = ruleObjects.compactMap { rule -> IngredientMatchRuleValue? in
            guard let leftKey = rule.value(forKey: "leftKey") as? String,
                  let rightKey = rule.value(forKey: "rightKey") as? String,
                  let kindRaw = rule.value(forKey: "kindRaw") as? String,
                  let kind = IngredientMatchRuleKind(rawValue: kindRaw) else { return nil }
            return IngredientMatchRuleValue(leftKey: leftKey, rightKey: rightKey, kind: kind)
        }
        return ManagedPantrySnapshot(
            householdID: householdID,
            ingredients: ingredients,
            shoppingItemKeys: shoppingItemKeys,
            matchRules: matchRules
        )
    }

    func shoppingListSnapshot(for householdID: UUID, range: DayRange) throws -> ManagedShoppingListSnapshot {
        let objectID = try managedHouseholdObjectID(for: householdID)
        let root = try container.viewContext.existingObject(with: objectID)
        let ingredientObjects = (root.value(forKey: "ingredients") as? NSSet)?.allObjects.compactMap { $0 as? NSManagedObject } ?? []
        let ingredients = ingredientObjects.compactMap(managedPantryIngredientSummary)
        let ingredientsByID = Dictionary(uniqueKeysWithValues: ingredients.map { ($0.id, $0) })
        let shoppingObjects = (root.value(forKey: "shoppingItems") as? NSSet)?.allObjects.compactMap { $0 as? NSManagedObject } ?? []
        let items = shoppingObjects.compactMap { item -> ManagedShoppingListItemSummary? in
            guard let id = item.value(forKey: "uuid") as? UUID,
                  let name = item.value(forKey: "name") as? String else { return nil }
            let linkedIngredientID = (item.value(forKey: "ingredient") as? NSManagedObject)?.value(forKey: "uuid") as? UUID
            return ManagedShoppingListItemSummary(
                id: id,
                name: name,
                displayText: item.value(forKey: "displayText") as? String,
                sourceDishNames: Self.stringArray(item.value(forKey: "sourceDishNames")),
                isChecked: (item.value(forKey: "isChecked") as? NSNumber)?.boolValue ?? false,
                isManual: (item.value(forKey: "isManual") as? NSNumber)?.boolValue ?? false,
                isStaple: linkedIngredientID.flatMap { ingredientsByID[$0]?.isPantryStaple } ?? false,
                categoryRaw: item.value(forKey: "categoryRaw") as? String ?? IngredientCategory.other.rawValue,
                customAisleName: item.value(forKey: "customAisleName") as? String,
                sortIndex: (item.value(forKey: "sortIndex") as? NSNumber)?.intValue ?? 0,
                rangeStart: item.value(forKey: "rangeStart") as? Date,
                rangeEnd: item.value(forKey: "rangeEnd") as? Date
            )
        }
        .sorted { ($0.sortIndex, $0.id.uuidString) < ($1.sortIndex, $1.id.uuidString) }
        let staples = ingredients.filter(\.isPantryStaple)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        let entries = try managedEntries(in: root, rootID: objectID, range: range)
        var missingNames: [String] = []
        var seenNames: Set<String> = []
        for entry in entries {
            guard let date = entry.value(forKey: "date") as? Date,
                  range.contains(date),
                  !((entry.value(forKey: "skipped") as? NSNumber)?.boolValue ?? false),
                  let dish = entry.value(forKey: "dish") as? NSManagedObject,
                  dish.value(forKey: "importedSourceApp") as? String == "KptnCook",
                  ((dish.value(forKey: "ingredients") as? NSSet)?.count ?? 0) == 0,
                  let name = dish.value(forKey: "name") as? String,
                  seenNames.insert(name).inserted else { continue }
            missingNames.append(name)
        }
        return ManagedShoppingListSnapshot(
            householdID: householdID,
            items: items,
            pantryStaples: staples,
            missingIngredientDishNames: missingNames
        )
    }

    func mealRoutineSnapshot(for householdID: UUID) throws -> ManagedMealRoutineSnapshot {
        let objectID = try managedHouseholdObjectID(for: householdID)
        let root = try container.viewContext.existingObject(with: objectID)
        let dishes = ((root.value(forKey: "dishes") as? NSSet)?.allObjects.compactMap { $0 as? NSManagedObject } ?? [])
            .compactMap { object -> ManagedDishChoice? in
                guard let id = object.value(forKey: "uuid") as? UUID,
                      let name = object.value(forKey: "name") as? String else { return nil }
                return ManagedDishChoice(id: id, name: name)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let mealTypes = ((root.value(forKey: "mealTypes") as? NSSet)?.allObjects.compactMap { $0 as? NSManagedObject } ?? [])
            .compactMap { object -> ManagedMealTypeChoice? in
                guard let id = object.value(forKey: "uuid") as? UUID,
                      let key = object.value(forKey: "key") as? String,
                      let name = object.value(forKey: "name") as? String else { return nil }
                return ManagedMealTypeChoice(
                    id: id,
                    key: key,
                    name: name,
                    symbolName: object.value(forKey: "symbolName") as? String ?? "fork.knife",
                    sortOrder: (object.value(forKey: "sortOrder") as? NSNumber)?.intValue ?? 0
                )
            }
            .sorted { ($0.sortOrder, $0.name) < ($1.sortOrder, $1.name) }
        let routines = ((root.value(forKey: "mealRoutines") as? NSSet)?.allObjects.compactMap { $0 as? NSManagedObject } ?? [])
            .compactMap { object -> ManagedMealRoutineSummary? in
                guard let id = object.value(forKey: "uuid") as? UUID,
                      let startDate = object.value(forKey: "startDate") as? Date else { return nil }
                let dish = object.value(forKey: "dish") as? NSManagedObject
                return ManagedMealRoutineSummary(
                    id: id,
                    dishID: dish?.value(forKey: "uuid") as? UUID,
                    dishName: dish?.value(forKey: "name") as? String,
                    mealKey: object.value(forKey: "mealKey") as? String ?? MealSlot.dinner.rawValue,
                    weekday: (object.value(forKey: "weekday") as? NSNumber)?.intValue ?? 3,
                    intervalWeeks: (object.value(forKey: "intervalWeeks") as? NSNumber)?.intValue ?? 1,
                    startDate: startDate,
                    isActive: (object.value(forKey: "isActive") as? NSNumber)?.boolValue ?? true,
                    plannedThrough: object.value(forKey: "plannedThrough") as? Date,
                    dateCreated: object.value(forKey: "dateCreated") as? Date ?? .distantPast
                )
            }
            .sorted { ($0.dateCreated, $0.id.uuidString) < ($1.dateCreated, $1.id.uuidString) }
        return ManagedMealRoutineSnapshot(householdID: householdID, routines: routines, dishes: dishes, mealTypes: mealTypes)
    }

    func mealTypeSnapshot(for householdID: UUID) throws -> [ManagedMealTypeChoice] {
        let objectID = try managedHouseholdObjectID(for: householdID)
        let root = try container.viewContext.existingObject(with: objectID)
        let records = (root.value(forKey: "mealTypes") as? NSSet)?.allObjects.compactMap { $0 as? NSManagedObject } ?? []
        var seenKeys: Set<String> = []
        return records.compactMap { object -> ManagedMealTypeChoice? in
            guard let id = object.value(forKey: "uuid") as? UUID,
                  let key = object.value(forKey: "key") as? String,
                  let name = object.value(forKey: "name") as? String else { return nil }
            return ManagedMealTypeChoice(
                id: id,
                key: key,
                name: name,
                symbolName: object.value(forKey: "symbolName") as? String ?? "fork.knife",
                sortOrder: (object.value(forKey: "sortOrder") as? NSNumber)?.intValue ?? 0
            )
        }
        .sorted { ($0.sortOrder, $0.id.uuidString) < ($1.sortOrder, $1.id.uuidString) }
        .filter { seenKeys.insert($0.key).inserted }
    }

    func addManagedMealType(in householdID: UUID) throws -> ManagedMealTypeChoice {
        let (rootID, root, context) = try editableHousehold(householdID)
        let records = (root.value(forKey: "mealTypes") as? NSSet)?.allObjects.compactMap { $0 as? NSManagedObject } ?? []
        let order = (records.compactMap { ($0.value(forKey: "sortOrder") as? NSNumber)?.intValue }.max() ?? -1) + 1
        let meal = try insert(.mealType, into: store(for: rootID), context: context)
        let key = UUID().uuidString
        meal.setValue(key, forKey: "key")
        meal.setValue("", forKey: "name")
        meal.setValue("fork.knife", forKey: "symbolName")
        meal.setValue(order, forKey: "sortOrder")
        meal.setValue(root, forKey: "household")
        root.mutableSetValue(forKey: "mealTypes").add(meal)
        try context.save()
        try finishManagedWrite(householdID: householdID, rootID: rootID)
        SharedStore.reloadWidgets()
        return ManagedMealTypeChoice(id: meal.value(forKey: "uuid") as? UUID ?? UUID(), key: key, name: "", symbolName: "fork.knife", sortOrder: order)
    }

    func updateManagedMealType(_ meal: ManagedMealTypeChoice, name: String, symbolName: String, in householdID: UUID) throws {
        let (rootID, root, context) = try editableHousehold(householdID)
        let records = (root.value(forKey: "mealTypes") as? NSSet)?.allObjects.compactMap { $0 as? NSManagedObject } ?? []
        guard let object = records.first(where: { $0.value(forKey: "uuid") as? UUID == meal.id }),
              canUpdate(object.objectID, in: rootID) else {
            throw MealPlanManagedCollaborationError.editingNotAllowed
        }
        object.setValue(name, forKey: "name")
        object.setValue(symbolName, forKey: "symbolName")
        object.setValue(Date.now, forKey: "modifiedAt")
        try context.save()
        try finishManagedWrite(householdID: householdID, rootID: rootID)
        SharedStore.reloadWidgets()
    }

    func reorderManagedMealTypes(_ meals: [ManagedMealTypeChoice], in householdID: UUID) throws {
        let (rootID, root, context) = try editableHousehold(householdID)
        let records = (root.value(forKey: "mealTypes") as? NSSet)?.allObjects.compactMap { $0 as? NSManagedObject } ?? []
        let byID = Dictionary(uniqueKeysWithValues: records.compactMap { record -> (UUID, NSManagedObject)? in
            guard let id = record.value(forKey: "uuid") as? UUID else { return nil }
            return (id, record)
        })
        for (index, meal) in meals.enumerated() {
            guard let object = byID[meal.id], canUpdate(object.objectID, in: rootID) else { continue }
            if (object.value(forKey: "sortOrder") as? NSNumber)?.intValue != index {
                object.setValue(index, forKey: "sortOrder")
                object.setValue(Date.now, forKey: "modifiedAt")
            }
        }
        guard context.hasChanges else { return }
        try context.save()
        try finishManagedWrite(householdID: householdID, rootID: rootID)
        SharedStore.reloadWidgets()
    }

    func managedPlannedMealCount(for mealKey: String, in householdID: UUID) throws -> Int {
        let rootID = try managedHouseholdObjectID(for: householdID)
        let root = try container.viewContext.existingObject(with: rootID)
        let request = NSFetchRequest<NSManagedObject>(entityName: ManagedHouseholdEntity.mealPlanEntry.rawValue)
        request.predicate = NSPredicate(format: "household == %@ AND mealSlotRaw == %@", root, mealKey)
        request.affectedStores = [try store(for: rootID)]
        return try container.viewContext.count(for: request)
    }

    func deleteManagedMealType(_ mealID: UUID, in householdID: UUID) throws {
        let (rootID, root, context) = try editableHousehold(householdID)
        let records = (root.value(forKey: "mealTypes") as? NSSet)?.allObjects.compactMap { $0 as? NSManagedObject } ?? []
        guard let meal = records.first(where: { $0.value(forKey: "uuid") as? UUID == mealID }),
              canUpdate(meal.objectID, in: rootID),
              let mealKey = meal.value(forKey: "key") as? String else {
            throw MealPlanManagedCollaborationError.editingNotAllowed
        }
        let request = NSFetchRequest<NSManagedObject>(entityName: ManagedHouseholdEntity.mealPlanEntry.rawValue)
        request.predicate = NSPredicate(format: "household == %@ AND mealSlotRaw == %@", root, mealKey)
        request.affectedStores = [try store(for: rootID)]
        for entry in try context.fetch(request) { context.delete(entry) }
        context.delete(meal)
        try context.save()
        try finishManagedWrite(householdID: householdID, rootID: rootID)
        SharedStore.reloadWidgets()
    }

    func addManagedMealRoutine(in householdID: UUID) throws -> ManagedMealRoutineDraft {
        let (rootID, root, context) = try editableHousehold(householdID)
        let dishes = (root.value(forKey: "dishes") as? NSSet)?.allObjects.compactMap { $0 as? NSManagedObject } ?? []
        let mealTypes = (root.value(forKey: "mealTypes") as? NSSet)?.allObjects.compactMap { $0 as? NSManagedObject } ?? []
        guard let dish = dishes.sorted(by: { ($0.value(forKey: "name") as? String ?? "") < ($1.value(forKey: "name") as? String ?? "") }).first else {
            throw MealPlanManagedCollaborationError.householdNotFound
        }
        let mealKeys = mealTypes.compactMap { $0.value(forKey: "key") as? String }
        let mealKey = mealKeys.contains(MealSlot.dinner.rawValue) ? MealSlot.dinner.rawValue : (mealKeys.first ?? MealSlot.dinner.rawValue)
        let routine = try insert(.mealRoutine, into: store(for: rootID), context: context)
        let today = Date.now.startOfDay
        routine.setValue(mealKey, forKey: "mealKey")
        routine.setValue(Calendar.current.component(.weekday, from: today), forKey: "weekday")
        routine.setValue(1, forKey: "intervalWeeks")
        routine.setValue(today, forKey: "startDate")
        routine.setValue(true, forKey: "isActive")
        routine.setValue(Date.now, forKey: "dateCreated")
        routine.setValue(dish, forKey: "dish")
        routine.setValue(root, forKey: "household")
        root.mutableSetValue(forKey: "mealRoutines").add(routine)
        try context.save()
        try finishManagedWrite(householdID: householdID, rootID: rootID)
        return ManagedMealRoutineDraft(
            id: routine.value(forKey: "uuid") as? UUID ?? UUID(),
            dishID: dish.value(forKey: "uuid") as? UUID,
            mealKey: mealKey,
            weekday: Calendar.current.component(.weekday, from: today),
            intervalWeeks: 1,
            startDate: today,
            isActive: true
        )
    }

    func saveManagedMealRoutine(
        _ draft: ManagedMealRoutineDraft,
        in householdID: UUID,
        through latestPlanningDate: Date? = nil,
        memberName: String = ""
    ) throws {
        let (rootID, root, context) = try editableHousehold(householdID)
        guard let routine = ((root.value(forKey: "mealRoutines") as? NSSet)?.allObjects.compactMap { $0 as? NSManagedObject } ?? [])
            .first(where: { $0.value(forKey: "uuid") as? UUID == draft.id }),
              canUpdate(routine.objectID, in: rootID) else {
            throw MealPlanManagedCollaborationError.editingNotAllowed
        }
        let dishes = (root.value(forKey: "dishes") as? NSSet)?.allObjects.compactMap { $0 as? NSManagedObject } ?? []
        let dish = draft.dishID.flatMap { id in dishes.first { $0.value(forKey: "uuid") as? UUID == id } }
        routine.setValue(dish, forKey: "dish")
        routine.setValue(draft.mealKey, forKey: "mealKey")
        routine.setValue(min(7, max(1, draft.weekday)), forKey: "weekday")
        routine.setValue(min(4, max(1, draft.intervalWeeks)), forKey: "intervalWeeks")
        routine.setValue(draft.startDate.startOfDay, forKey: "startDate")
        routine.setValue(draft.isActive, forKey: "isActive")
        routine.setValue(nil, forKey: "plannedThrough")
        routine.setValue(Date.now, forKey: "modifiedAt")
        if draft.isActive, dish != nil {
            try planManagedRoutines(
                [routine], root: root, rootID: rootID, context: context,
                through: latestPlanningDate, memberName: memberName
            )
        }
        try context.save()
        try finishManagedWrite(householdID: householdID, rootID: rootID)
        SharedStore.reloadWidgets()
    }

    func deleteManagedMealRoutine(_ routineID: UUID, in householdID: UUID) throws {
        let (rootID, root, context) = try editableHousehold(householdID)
        guard let routine = ((root.value(forKey: "mealRoutines") as? NSSet)?.allObjects.compactMap { $0 as? NSManagedObject } ?? [])
            .first(where: { $0.value(forKey: "uuid") as? UUID == routineID }),
              canUpdate(routine.objectID, in: rootID) else {
            throw MealPlanManagedCollaborationError.editingNotAllowed
        }
        let today = Date.now.startOfDay
        let entryRequest = NSFetchRequest<NSManagedObject>(entityName: ManagedHouseholdEntity.mealPlanEntry.rawValue)
        entryRequest.predicate = NSPredicate(format: "household == %@ AND routineUUID == %@ AND date >= %@", root, routineID as NSUUID, today as NSDate)
        entryRequest.affectedStores = [try store(for: rootID)]
        for entry in try context.fetch(entryRequest) { context.delete(entry) }
        context.delete(routine)
        try context.save()
        try finishManagedWrite(householdID: householdID, rootID: rootID)
        SharedStore.reloadWidgets()
    }

    func applyManagedMealRoutines(
        for householdID: UUID,
        through latestPlanningDate: Date? = nil,
        memberName: String = ""
    ) throws {
        let (rootID, root, context) = try editableHousehold(householdID)
        let routines = ((root.value(forKey: "mealRoutines") as? NSSet)?.allObjects.compactMap { $0 as? NSManagedObject } ?? [])
            .filter { ($0.value(forKey: "isActive") as? NSNumber)?.boolValue ?? false }
        guard !routines.isEmpty else { return }
        try planManagedRoutines(
            routines, root: root, rootID: rootID, context: context,
            through: latestPlanningDate, memberName: memberName
        )
        if context.hasChanges {
            try context.save()
            try finishManagedWrite(householdID: householdID, rootID: rootID)
            SharedStore.reloadWidgets()
        }
    }

    func setPantryStaple(_ isStaple: Bool, ingredientID: UUID, in householdID: UUID) throws {
        let (rootID, root, context) = try editableHousehold(householdID)
        let ingredientObjects = (root.value(forKey: "ingredients") as? NSSet)?.allObjects.compactMap { $0 as? NSManagedObject } ?? []
        guard let ingredient = ingredientObjects.first(where: { $0.value(forKey: "uuid") as? UUID == ingredientID }),
              canUpdate(ingredient.objectID, in: rootID) else {
            throw MealPlanManagedCollaborationError.editingNotAllowed
        }
        ingredient.setValue(isStaple, forKey: "isPantryStaple")
        ingredient.setValue(Date.now, forKey: "modifiedAt")
        try context.save()
        try finishManagedWrite(householdID: householdID, rootID: rootID)
    }

    func addPantryStaple(named rawName: String, in householdID: UUID) throws {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let snapshot = try pantrySnapshot(for: householdID)
        if let existingID = IngredientMatching.matchID(name, in: snapshot.ingredients.map(\.matchValue), rules: snapshot.matchRules) {
            try setPantryStaple(true, ingredientID: existingID, in: householdID)
            return
        }

        let (rootID, root, context) = try editableHousehold(householdID)
        let store = try store(for: rootID)
        let ingredient = try insert(.ingredient, into: store, context: context)
        ingredient.setValue(name, forKey: "name")
        ingredient.setValue(Ingredient.normalize(name), forKey: "normalizedName")
        ingredient.setValue(IngredientCategory.other.rawValue, forKey: "categoryRaw")
        ingredient.setValue(InventoryMode.none.rawValue, forKey: "inventoryModeRaw")
        ingredient.setValue(try JSONEncoder().encode([String]()), forKey: "rejectedMatchKeys")
        ingredient.setValue(true, forKey: "isPantryStaple")
        ingredient.setValue(root, forKey: "household")
        root.mutableSetValue(forKey: "ingredients").add(ingredient)
        try context.save()
        try finishManagedWrite(householdID: householdID, rootID: rootID)
    }

    func addPantryStapleToShoppingList(ingredientID: UUID, in householdID: UUID) throws {
        let (rootID, root, context) = try editableHousehold(householdID)
        let ingredientObjects = (root.value(forKey: "ingredients") as? NSSet)?.allObjects.compactMap { $0 as? NSManagedObject } ?? []
        guard let ingredient = ingredientObjects.first(where: { $0.value(forKey: "uuid") as? UUID == ingredientID }),
              canUpdate(ingredient.objectID, in: rootID) else {
            throw MealPlanManagedCollaborationError.editingNotAllowed
        }
        let name = ingredient.value(forKey: "name") as? String ?? ""
        let key = IngredientMatching.key(for: name)
        let existingItems = (root.value(forKey: "shoppingItems") as? NSSet)?.allObjects.compactMap { $0 as? NSManagedObject } ?? []
        guard !existingItems.contains(where: { item in
            guard let itemName = item.value(forKey: "name") as? String else { return false }
            return IngredientMatching.key(for: itemName) == key
        }) else { return }
        let categoryRaw = ingredient.value(forKey: "categoryRaw") as? String ?? IngredientCategory.other.rawValue
        let category = IngredientCategory(rawValue: categoryRaw) ?? .other
        let item = try insert(.shoppingListItem, into: store(for: rootID), context: context)
        let now = Date.now
        item.setValue(now, forKey: "contentModifiedAt")
        item.setValue(now, forKey: "checkStateModifiedAt")
        item.setValue(name, forKey: "name")
        item.setValue(Ingredient.normalize(name), forKey: "normalizedName")
        item.setValue(category.rawValue, forKey: "categoryRaw")
        item.setValue(ingredient.value(forKey: "customAisleName"), forKey: "customAisleName")
        item.setValue(try JSONEncoder().encode([String]()), forKey: "additionalAmountsRaw")
        item.setValue(0, forKey: "unmeasuredCount")
        item.setValue(false, forKey: "isChecked")
        item.setValue(true, forKey: "isManual")
        item.setValue(false, forKey: "isApproximate")
        item.setValue(category.sortOrder * 1_000 + 999, forKey: "sortIndex")
        item.setValue(try JSONEncoder().encode([String]()), forKey: "sourceDishNames")
        item.setValue(now, forKey: "dateCreated")
        item.setValue(ingredient, forKey: "ingredient")
        item.setValue(root, forKey: "household")
        root.mutableSetValue(forKey: "shoppingItems").add(item)
        try context.save()
        try finishManagedWrite(householdID: householdID, rootID: rootID)
    }

    func setShoppingItemChecked(_ checked: Bool, itemID: UUID, in householdID: UUID) throws {
        let (rootID, root, context) = try editableHousehold(householdID)
        guard let item = shoppingItems(in: root).first(where: { $0.value(forKey: "uuid") as? UUID == itemID }),
              canUpdate(item.objectID, in: rootID) else {
            throw MealPlanManagedCollaborationError.editingNotAllowed
        }
        guard (item.value(forKey: "isChecked") as? NSNumber)?.boolValue != checked else { return }
        let now = Date.now
        item.setValue(checked, forKey: "isChecked")
        item.setValue(now, forKey: "checkStateModifiedAt")
        item.setValue(now, forKey: "modifiedAt")
        try context.save()
        try finishManagedWrite(householdID: householdID, rootID: rootID)
        SharedStore.reloadWidgets()
    }

    func deleteShoppingItems(_ itemIDs: some Sequence<UUID>, in householdID: UUID) throws {
        let ids = Set(itemIDs)
        guard !ids.isEmpty else { return }
        let (rootID, root, context) = try editableHousehold(householdID)
        let matches = shoppingItems(in: root).filter { item in
            guard let id = item.value(forKey: "uuid") as? UUID else { return false }
            return ids.contains(id) && canUpdate(item.objectID, in: rootID)
        }
        guard !matches.isEmpty else { return }
        for item in matches { context.delete(item) }
        try context.save()
        try finishManagedWrite(householdID: householdID, rootID: rootID)
        SharedStore.reloadWidgets()
    }

    func addManagedShoppingItem(
        named text: String,
        householdID: UUID,
        system: UnitSystem,
        roundsAmounts: Bool = true
    ) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let parsed = GermanUnitParser.parse(trimmed)
        let name = parsed.name.isEmpty ? trimmed : parsed.name
        let (rootID, root, context) = try editableHousehold(householdID)
        let snapshot = try pantrySnapshot(for: householdID)
        let ingredientID = IngredientMatching.matchID(
            name,
            in: snapshot.ingredients.map(\.matchValue),
            rules: snapshot.matchRules
        )
        let ingredient = ingredientID.flatMap { id in
            managedIngredients(in: root).first { $0.value(forKey: "uuid") as? UUID == id }
        }
        let categoryRaw = ingredient?.value(forKey: "categoryRaw") as? String ?? IngredientCategory.other.rawValue
        let category = IngredientCategory(rawValue: categoryRaw) ?? .other
        let item = try insert(.shoppingListItem, into: store(for: rootID), context: context)
        let now = Date.now
        item.setValue(now, forKey: "contentModifiedAt")
        item.setValue(now, forKey: "checkStateModifiedAt")
        item.setValue(name, forKey: "name")
        item.setValue(Ingredient.normalize(name), forKey: "normalizedName")
        item.setValue(category.rawValue, forKey: "categoryRaw")
        item.setValue(ingredient?.value(forKey: "customAisleName"), forKey: "customAisleName")
        item.setValue(try JSONEncoder().encode([String]()), forKey: "additionalAmountsRaw")
        item.setValue(0, forKey: "unmeasuredCount")
        item.setValue(false, forKey: "isChecked")
        item.setValue(true, forKey: "isManual")
        item.setValue(parsed.isApproximate, forKey: "isApproximate")
        item.setValue(category.sortOrder * 1_000 + 999, forKey: "sortIndex")
        item.setValue(try JSONEncoder().encode([String]()), forKey: "sourceDishNames")
        item.setValue(now, forKey: "dateCreated")
        item.setValue(ingredient, forKey: "ingredient")
        item.setValue(root, forKey: "household")
        if let quantity = parsed.quantity {
            let line = AggregatedLine(
                name: name,
                normalizedName: Ingredient.normalize(name),
                category: category,
                quantity: quantity,
                displayUnit: parsed.displayUnit,
                isApproximate: parsed.isApproximate
            )
            item.setValue(quantity.value, forKey: "canonicalValue")
            item.setValue(quantity.dimension.rawValue, forKey: "canonicalDimensionRaw")
            item.setValue(parsed.displayUnit, forKey: "displayUnit")
            item.setValue(ShoppingListBuilder.displayText(for: line, system: system, roundsAmounts: roundsAmounts), forKey: "displayText")
        }
        root.mutableSetValue(forKey: "shoppingItems").add(item)
        try context.save()
        try finishManagedWrite(householdID: householdID, rootID: rootID)
        SharedStore.reloadWidgets()
    }

    func changeShoppingItemCategory(_ category: IngredientCategory, itemID: UUID, in householdID: UUID) throws {
        let (rootID, root, context) = try editableHousehold(householdID)
        guard let item = shoppingItems(in: root).first(where: { $0.value(forKey: "uuid") as? UUID == itemID }),
              canUpdate(item.objectID, in: rootID) else {
            throw MealPlanManagedCollaborationError.editingNotAllowed
        }
        item.setValue(category.rawValue, forKey: "categoryRaw")
        let current = (item.value(forKey: "sortIndex") as? NSNumber)?.intValue ?? 0
        item.setValue(category.sortOrder * 1_000 + current % 1_000, forKey: "sortIndex")
        item.setValue(Date.now, forKey: "contentModifiedAt")
        item.setValue(Date.now, forKey: "modifiedAt")
        if let ingredient = item.value(forKey: "ingredient") as? NSManagedObject {
            ingredient.setValue(category.rawValue, forKey: "categoryRaw")
            ingredient.setValue(Date.now, forKey: "modifiedAt")
        }
        try context.save()
        try finishManagedWrite(householdID: householdID, rootID: rootID)
    }

    func setShoppingItemAisle(_ aisle: String?, itemID: UUID, in householdID: UUID) throws {
        let (rootID, root, context) = try editableHousehold(householdID)
        guard let item = shoppingItems(in: root).first(where: { $0.value(forKey: "uuid") as? UUID == itemID }),
              canUpdate(item.objectID, in: rootID) else {
            throw MealPlanManagedCollaborationError.editingNotAllowed
        }
        let trimmed = aisle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let value: String? = trimmed.isEmpty ? nil : trimmed
        item.setValue(value, forKey: "customAisleName")
        item.setValue(Date.now, forKey: "contentModifiedAt")
        item.setValue(Date.now, forKey: "modifiedAt")
        if let ingredient = item.value(forKey: "ingredient") as? NSManagedObject {
            ingredient.setValue(value, forKey: "customAisleName")
            ingredient.setValue(Date.now, forKey: "modifiedAt")
        }
        try context.save()
        try finishManagedWrite(householdID: householdID, rootID: rootID)
    }

    func setShoppingItemStaple(_ isStaple: Bool, itemID: UUID, in householdID: UUID) throws {
        let (rootID, root, context) = try editableHousehold(householdID)
        guard let item = shoppingItems(in: root).first(where: { $0.value(forKey: "uuid") as? UUID == itemID }),
              canUpdate(item.objectID, in: rootID) else {
            throw MealPlanManagedCollaborationError.editingNotAllowed
        }
        var ingredient = item.value(forKey: "ingredient") as? NSManagedObject
        if ingredient == nil, isStaple {
            let itemName = item.value(forKey: "name") as? String ?? ""
            let snapshot = try pantrySnapshot(for: householdID)
            let matchedID = IngredientMatching.matchID(itemName, in: snapshot.ingredients.map(\.matchValue), rules: snapshot.matchRules)
            ingredient = matchedID.flatMap { id in managedIngredients(in: root).first { $0.value(forKey: "uuid") as? UUID == id } }
            if ingredient == nil {
                let created = try insert(.ingredient, into: store(for: rootID), context: context)
                created.setValue(itemName, forKey: "name")
                created.setValue(Ingredient.normalize(itemName), forKey: "normalizedName")
                created.setValue(item.value(forKey: "categoryRaw") as? String ?? IngredientCategory.other.rawValue, forKey: "categoryRaw")
                created.setValue(InventoryMode.none.rawValue, forKey: "inventoryModeRaw")
                created.setValue(try JSONEncoder().encode([String]()), forKey: "rejectedMatchKeys")
                created.setValue(root, forKey: "household")
                root.mutableSetValue(forKey: "ingredients").add(created)
                ingredient = created
            }
            item.setValue(ingredient, forKey: "ingredient")
        }
        ingredient?.setValue(isStaple, forKey: "isPantryStaple")
        ingredient?.setValue(Date.now, forKey: "modifiedAt")
        if isStaple, !((item.value(forKey: "isManual") as? NSNumber)?.boolValue ?? false) {
            context.delete(item)
        }
        try context.save()
        try finishManagedWrite(householdID: householdID, rootID: rootID)
        SharedStore.reloadWidgets()
    }

    func markShoppingItemOwned(_ itemID: UUID, in householdID: UUID, range: DayRange, system: UnitSystem, roundsAmounts: Bool = true) throws {
        let (rootID, root, context) = try editableHousehold(householdID)
        guard let item = shoppingItems(in: root).first(where: { $0.value(forKey: "uuid") as? UUID == itemID }),
              canUpdate(item.objectID, in: rootID) else {
            throw MealPlanManagedCollaborationError.editingNotAllowed
        }
        var ingredient = item.value(forKey: "ingredient") as? NSManagedObject
        if ingredient == nil {
            let itemName = item.value(forKey: "name") as? String ?? ""
            let snapshot = try pantrySnapshot(for: householdID)
            let matchedID = IngredientMatching.matchID(itemName, in: snapshot.ingredients.map(\.matchValue), rules: snapshot.matchRules)
            ingredient = matchedID.flatMap { id in managedIngredients(in: root).first { $0.value(forKey: "uuid") as? UUID == id } }
            if ingredient == nil {
                let created = try insert(.ingredient, into: store(for: rootID), context: context)
                created.setValue(itemName, forKey: "name")
                created.setValue(Ingredient.normalize(itemName), forKey: "normalizedName")
                created.setValue(item.value(forKey: "categoryRaw") as? String ?? IngredientCategory.other.rawValue, forKey: "categoryRaw")
                created.setValue(InventoryMode.none.rawValue, forKey: "inventoryModeRaw")
                created.setValue(try JSONEncoder().encode([String]()), forKey: "rejectedMatchKeys")
                created.setValue(root, forKey: "household")
                root.mutableSetValue(forKey: "ingredients").add(created)
                ingredient = created
            }
            item.setValue(ingredient, forKey: "ingredient")
        }
        root.setValue(true, forKey: "inventoryEnabled")
        let now = Date.now
        ingredient?.setValue(InventoryMode.have.rawValue, forKey: "inventoryModeRaw")
        ingredient?.setValue(item.value(forKey: "canonicalValue"), forKey: "inventoryCanonicalValue")
        ingredient?.setValue(item.value(forKey: "canonicalDimensionRaw"), forKey: "inventoryDimensionRaw")
        ingredient?.setValue(now, forKey: "inventoryUpdatedAt")
        ingredient?.setValue(now, forKey: "modifiedAt")
        try context.save()
        try finishManagedWrite(householdID: householdID, rootID: rootID)
        try regenerateShoppingList(for: householdID, range: range, system: system, roundsAmounts: roundsAmounts)
    }

    func regenerateShoppingList(for householdID: UUID, range: DayRange, system: UnitSystem, roundsAmounts: Bool = true) throws {
        let (rootID, root, context) = try editableHousehold(householdID)
        let managedIngredients = managedIngredients(in: root)
        let domainIngredients = managedIngredients.compactMap(managedIngredientModel)
        let domainByID = Dictionary(uniqueKeysWithValues: domainIngredients.map { ($0.uuid, $0) })
        let ruleValues = managedMatchRules(in: root)
        let domainRules = ruleValues.map { value -> IngredientMatchRule in
            let rule = IngredientMatchRule()
            rule.leftKey = value.leftKey
            rule.rightKey = value.rightKey
            rule.kindRaw = value.kind.rawValue
            return rule
        }
        let staples = Set(domainIngredients.filter(\.isPantryStaple).map { IngredientMatching.key(for: $0.name) })
        let sourceEntries = try managedEntries(in: root, rootID: rootID, range: range)
        let standardServings = max(1, (root.value(forKey: "standardServings") as? NSNumber)?.intValue ?? Household.defaultStandardServings)
        let entries = sourceEntries.compactMap { managedEntry -> MealPlanEntry? in
            guard let date = managedEntry.value(forKey: "date") as? Date,
                  let managedDish = managedEntry.value(forKey: "dish") as? NSManagedObject,
                  let dishName = managedDish.value(forKey: "name") as? String else { return nil }
            let dish = Dish(name: dishName)
            dish.servings = max(1, (managedDish.value(forKey: "servings") as? NSNumber)?.intValue ?? 2)
            dish.importedSourceApp = managedDish.value(forKey: "importedSourceApp") as? String
            let managedDishIngredients = (managedDish.value(forKey: "ingredients") as? NSSet)?.allObjects.compactMap { $0 as? NSManagedObject } ?? []
            dish.ingredients = managedDishIngredients.compactMap { managedLine -> DishIngredient? in
                let line = DishIngredient(
                    canonicalValue: (managedLine.value(forKey: "canonicalValue") as? NSNumber)?.doubleValue,
                    dimension: (managedLine.value(forKey: "canonicalDimensionRaw") as? String).flatMap(QuantityDimension.init(rawValue:)),
                    displayUnit: managedLine.value(forKey: "displayUnit") as? String,
                    isApproximate: (managedLine.value(forKey: "isApproximate") as? NSNumber)?.boolValue ?? false,
                    note: managedLine.value(forKey: "note") as? String,
                    rawText: managedLine.value(forKey: "rawText") as? String,
                    sortIndex: (managedLine.value(forKey: "sortIndex") as? NSNumber)?.intValue ?? 0
                )
                if let ingredientObject = managedLine.value(forKey: "ingredient") as? NSManagedObject,
                   let ingredientID = ingredientObject.value(forKey: "uuid") as? UUID,
                   let ingredient = domainByID[ingredientID] {
                    line.ingredient = ingredient
                }
                line.dish = dish
                return line
            }
            let entry = MealPlanEntry(date: date, mealKey: managedEntry.value(forKey: "mealSlotRaw") as? String ?? MealSlot.dinner.rawValue, dish: dish)
            entry.skipped = false
            entry.servingsOverride = max(1, (managedEntry.value(forKey: "servingsOverride") as? NSNumber)?.intValue ?? standardServings)
            entry.dish = dish
            return entry
        }
        let aggregated = ShoppingListBuilder.aggregate(entries, stapleKeys: staples, matchRules: domainRules)
            .compactMap { line -> AggregatedLine? in
                guard (root.value(forKey: "inventoryEnabled") as? NSNumber)?.boolValue == true,
                      let ingredient = IngredientMatching.match(line.name, in: domainIngredients, rules: domainRules) else { return line }
                return ShoppingListBuilder.subtractingInventory(line, ingredient: ingredient)
            }

        var oldByKey = Dictionary(grouping: shoppingItems(in: root).filter { !(( $0.value(forKey: "isManual") as? NSNumber)?.boolValue ?? false) }) {
            IngredientMatching.key(for: $0.value(forKey: "name") as? String ?? "")
        }.mapValues { $0.sorted {
            (($0.value(forKey: "uuid") as? UUID)?.uuidString ?? "") < (($1.value(forKey: "uuid") as? UUID)?.uuidString ?? "")
        } }
        let ruleCandidates = managedIngredients.compactMap { object -> IngredientMatchCandidateValue? in
            guard let summary = managedPantryIngredientSummary(object) else { return nil }
            return summary.matchValue
        }
        for (index, line) in aggregated.enumerated() {
            let key = IngredientMatching.key(for: line.name)
            let item: NSManagedObject
            let isNew: Bool
            if var bucket = oldByKey[key], let reused = bucket.first {
                item = reused
                isNew = false
                bucket.removeFirst()
                oldByKey[key] = bucket
            } else {
                item = try insert(.shoppingListItem, into: store(for: rootID), context: context)
                isNew = true
                item.setValue(false, forKey: "isManual")
                item.setValue(false, forKey: "isChecked")
                item.setValue(Date.now, forKey: "checkStateModifiedAt")
                item.setValue(try JSONEncoder().encode([String]()), forKey: "additionalAmountsRaw")
                item.setValue(try JSONEncoder().encode([String]()), forKey: "sourceDishNames")
                item.setValue(0, forKey: "unmeasuredCount")
                item.setValue(false, forKey: "isApproximate")
                item.setValue(Date.now, forKey: "dateCreated")
                item.setValue(root, forKey: "household")
                root.mutableSetValue(forKey: "shoppingItems").add(item)
            }
            let now = Date.now
            var changed = isNew
            func assign(_ value: Any?, forKey key: String) {
                if !Self.managedValuesEqual(item.value(forKey: key), value) {
                    item.setValue(value, forKey: key)
                    changed = true
                }
            }
            assign(line.name, forKey: "name")
            assign(line.normalizedName, forKey: "normalizedName")
            assign(line.category.rawValue, forKey: "categoryRaw")
            assign(line.customAisleName, forKey: "customAisleName")
            assign(line.quantity?.value, forKey: "canonicalValue")
            assign(line.quantity?.dimension.rawValue, forKey: "canonicalDimensionRaw")
            assign(try JSONEncoder().encode(line.additionalQuantities.map(\.encoded)), forKey: "additionalAmountsRaw")
            assign(line.unmeasuredCount, forKey: "unmeasuredCount")
            assign(line.displayUnit, forKey: "displayUnit")
            assign(line.isApproximate, forKey: "isApproximate")
            assign(ShoppingListBuilder.displayText(for: line, system: system, roundsAmounts: roundsAmounts), forKey: "displayText")
            assign(try JSONEncoder().encode(line.sourceDishNames), forKey: "sourceDishNames")
            assign(range.start, forKey: "rangeStart")
            assign(range.end, forKey: "rangeEnd")
            assign(line.category.sortOrder * 1_000 + index, forKey: "sortIndex")
            let linkedID = IngredientMatching.matchID(line.name, in: ruleCandidates, rules: ruleValues)
            let linkedIngredient = linkedID.flatMap { id in managedIngredients.first { $0.value(forKey: "uuid") as? UUID == id } }
            let currentLinkedID = (item.value(forKey: "ingredient") as? NSManagedObject)?.value(forKey: "uuid") as? UUID
            if currentLinkedID != linkedID {
                item.setValue(linkedIngredient, forKey: "ingredient")
                changed = true
            }
            if changed {
                item.setValue(now, forKey: "contentModifiedAt")
                item.setValue(now, forKey: "modifiedAt")
            }
        }
        for stale in oldByKey.values.flatMap({ $0 }) { context.delete(stale) }
        try context.save()
        try finishManagedWrite(householdID: householdID, rootID: rootID)
        SharedStore.reloadWidgets()
    }

    func makeSession(for household: ManagedHouseholdSummary) -> ManagedCollaborationSession {
        ManagedCollaborationSession(
            rootID: household.id.uuidString,
            title: household.name,
            service: sharing
        )
    }

    func makeVerifiedSession(for household: ManagedHouseholdSummary) throws -> ManagedCollaborationSession {
        guard isVerifiedManagedHousehold(household.id) else {
            throw MealPlanManagedCollaborationError.householdNotFound
        }
        return makeSession(for: household)
    }

    func isVerifiedManagedHousehold(_ householdID: UUID) -> Bool {
        guard let objectID = try? managedHouseholdObjectID(for: householdID),
              let root = try? container.viewContext.existingObject(with: objectID),
              root.value(forKey: "managedMigrationPhaseRaw") as? String == "verified",
              let count = root.value(forKey: "managedGraphObjectCount") as? NSNumber,
              count.intValue > 0 else { return false }
        // The durable marker is written only after migration validates every
        // object and relationship. Full share-boundary validation runs on a
        // background context when the person explicitly starts an invitation.
        // Do not rescan the complete graph on the main actor during view refresh.
        return true
    }

    func reinviteNoticeWasDismissed(for householdID: UUID) -> Bool {
        guard let objectID = try? managedHouseholdObjectID(for: householdID),
              let root = try? container.viewContext.existingObject(with: objectID) else { return false }
        return root.value(forKey: "reinviteNoticeDismissedAt") as? Date != nil
    }

    func dismissReinviteNotice(for householdID: UUID) throws {
        let objectID = try sharing.resolveRootObjectID(householdID.uuidString)
        let context = container.viewContext
        let root = try context.existingObject(with: objectID)
        root.setValue(Date.now, forKey: "reinviteNoticeDismissedAt")
        if context.hasChanges { try context.save() }
        try ManagedHouseholdRolloutAuthority.shared.markReinviteNoticeDismissed(for: householdID)
    }

    func updateHouseholdName(_ name: String, for householdID: UUID) throws {
        try updateHousehold(for: householdID) { root in
            root.setValue(name, forKey: "name")
        }
    }

    func updateStandardServings(_ servings: Int, for householdID: UUID) throws {
        try updateHousehold(for: householdID) { root in
            root.setValue(max(1, servings), forKey: "standardServings")
        }
    }

    func updateFoodProfile(_ member: ManagedHouseholdMemberSummary, in householdID: UUID) throws {
        let rootID = try managedHouseholdObjectID(for: householdID)
        let access = sharing.effectiveAccess(for: rootID).level
        guard access == .owner || access == .editor,
              container.canUpdateRecord(forManagedObjectWith: rootID) else {
            throw MealPlanManagedCollaborationError.editingNotAllowed
        }
        let context = container.viewContext
        let root = try context.existingObject(with: rootID)
        let records = (root.value(forKey: "members") as? NSSet)?.allObjects.compactMap { $0 as? NSManagedObject } ?? []
        guard let object = records.first(where: { $0.value(forKey: "uuid") as? UUID == member.id }),
              container.canUpdateRecord(forManagedObjectWith: object.objectID) else {
            throw MealPlanManagedCollaborationError.editingNotAllowed
        }
        object.setValue(try JSONEncoder().encode(member.allergies), forKey: "allergies")
        object.setValue(try JSONEncoder().encode(member.mustAvoidIngredients), forKey: "mustAvoidIngredients")
        object.setValue(try JSONEncoder().encode(member.dietaryPatterns), forKey: "dietaryPatterns")
        object.setValue(try JSONEncoder().encode(member.dislikes), forKey: "dislikes")
        object.setValue(try JSONEncoder().encode(member.favorites), forKey: "favorites")
        object.setValue(try JSONEncoder().encode(member.preferredCuisines), forKey: "preferredCuisines")
        object.setValue(member.spiceTolerance.map { NSNumber(value: $0) }, forKey: "spiceTolerance")
        object.setValue(Date.now, forKey: "profileModifiedAt")
        object.setValue(Date.now, forKey: "modifiedAt")
        try context.save()
        if rootID.persistentStore === privateStore {
            try ManagedHouseholdRolloutAuthority.shared.recordManagedWrite(for: householdID)
        }
        NotificationCenter.default.post(name: .mealPlanManagedStoreDidChange, object: nil)
    }

    private func updateHousehold(
        for householdID: UUID,
        mutate: (NSManagedObject) -> Void
    ) throws {
        let objectID = try managedHouseholdObjectID(for: householdID)
        let access = sharing.effectiveAccess(for: objectID).level
        guard access == .owner || access == .editor,
              container.canUpdateRecord(forManagedObjectWith: objectID) else {
            throw MealPlanManagedCollaborationError.editingNotAllowed
        }
        let context = container.viewContext
        let root = try context.existingObject(with: objectID)
        mutate(root)
        root.setValue(Date.now, forKey: "modifiedAt")
        try context.save()
        if objectID.persistentStore === privateStore {
            try ManagedHouseholdRolloutAuthority.shared.recordManagedWrite(for: householdID)
        }
        NotificationCenter.default.post(name: .mealPlanManagedStoreDidChange, object: nil)
    }

    private static func stringArray(_ value: Any?) -> [String] {
        guard let data = value as? Data else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    private static func managedValuesEqual(_ lhs: Any?, _ rhs: Any?) -> Bool {
        guard let lhs, let rhs else { return lhs == nil && rhs == nil }
        if let lhs = lhs as? NSNumber, let rhs = rhs as? NSNumber { return lhs == rhs }
        if let lhs = lhs as? NSObject { return lhs.isEqual(rhs) }
        return false
    }

    func prepareVerifiedShare(rootID: String) async throws -> CKShare {
        guard let householdID = UUID(uuidString: rootID), isVerifiedManagedHousehold(householdID) else {
            throw MealPlanManagedCollaborationError.householdNotFound
        }
        return try await sharing.prepareShare(rootID: rootID)
    }

    func existingShare(for household: ManagedHouseholdSummary) throws -> CKShare? {
        try sharing.existingShare(for: sharing.resolveRootObjectID(household.id.uuidString))
    }

    func effectiveAccess(for household: ManagedHouseholdSummary) -> AccessLevel {
        effectiveAccess(for: household.id)
    }

    func effectiveAccess(for householdID: UUID) -> AccessLevel {
        guard let objectID = try? managedHouseholdObjectID(for: householdID) else {
            return .unavailable
        }
        return sharing.effectiveAccess(for: objectID).level
    }

    private func editableHousehold(
        _ householdID: UUID
    ) throws -> (NSManagedObjectID, NSManagedObject, NSManagedObjectContext) {
        let rootID = try managedHouseholdObjectID(for: householdID)
        let access = sharing.effectiveAccess(for: rootID).level
        guard access == .owner || access == .editor,
              container.canUpdateRecord(forManagedObjectWith: rootID),
              rootID.persistentStore === privateStore || rootID.persistentStore === sharedStore else {
            throw MealPlanManagedCollaborationError.editingNotAllowed
        }
        let context = container.viewContext
        let root = try context.existingObject(with: rootID)
        guard root.value(forKey: "managedMigrationPhaseRaw") as? String == "verified" else {
            throw MealPlanManagedCollaborationError.householdNotFound
        }
        return (rootID, root, context)
    }

    private func canUpdate(_ objectID: NSManagedObjectID, in rootID: NSManagedObjectID) -> Bool {
        guard let objectStore = objectID.persistentStore,
              let rootStore = rootID.persistentStore,
              objectStore === rootStore,
              container.canUpdateRecord(forManagedObjectWith: rootID),
              container.canUpdateRecord(forManagedObjectWith: objectID) else { return false }
        let access = sharing.effectiveAccess(for: rootID).level
        return access == .owner || access == .editor
    }

    private func store(for rootID: NSManagedObjectID) throws -> NSPersistentStore {
        guard let store = rootID.persistentStore,
              store === privateStore || store === sharedStore else {
            throw MealPlanManagedCollaborationError.invalidRootStore
        }
        return store
    }

    private func managedIngredients(in root: NSManagedObject) -> [NSManagedObject] {
        (root.value(forKey: "ingredients") as? NSSet)?.allObjects.compactMap { $0 as? NSManagedObject } ?? []
    }

    private func shoppingItems(in root: NSManagedObject) -> [NSManagedObject] {
        (root.value(forKey: "shoppingItems") as? NSSet)?.allObjects.compactMap { $0 as? NSManagedObject } ?? []
    }

    private func managedEntries(in root: NSManagedObject, rootID: NSManagedObjectID, range: DayRange) throws -> [NSManagedObject] {
        let request = NSFetchRequest<NSManagedObject>(entityName: ManagedHouseholdEntity.mealPlanEntry.rawValue)
        request.predicate = NSPredicate(
            format: "household == %@ AND date >= %@ AND date < %@ AND skipped == NO",
            root,
            range.start as NSDate,
            range.end as NSDate
        )
        request.sortDescriptors = [
            NSSortDescriptor(key: "date", ascending: true),
            NSSortDescriptor(key: "sortIndex", ascending: true),
        ]
        request.affectedStores = [try store(for: rootID)]
        return try container.viewContext.fetch(request)
    }

    private func managedPantryIngredientSummary(_ ingredient: NSManagedObject) -> ManagedPantryIngredientSummary? {
        guard let id = ingredient.value(forKey: "uuid") as? UUID,
              let name = ingredient.value(forKey: "name") as? String else { return nil }
        let aliasObjects = (ingredient.value(forKey: "aliases") as? NSSet)?.allObjects.compactMap { $0 as? NSManagedObject } ?? []
        let aliases = aliasObjects.compactMap { alias -> IngredientMatchAliasValue? in
            guard let aliasName = alias.value(forKey: "name") as? String,
                  let normalizedName = alias.value(forKey: "normalizedName") as? String else { return nil }
            return IngredientMatchAliasValue(
                name: aliasName,
                normalizedName: normalizedName,
                sourceRaw: alias.value(forKey: "sourceRaw") as? String ?? IngredientAliasSource.automatic.rawValue
            )
        }
        return ManagedPantryIngredientSummary(
            id: id,
            name: name,
            normalizedName: ingredient.value(forKey: "normalizedName") as? String ?? Ingredient.normalize(name),
            categoryRaw: ingredient.value(forKey: "categoryRaw") as? String ?? IngredientCategory.other.rawValue,
            customAisleName: ingredient.value(forKey: "customAisleName") as? String,
            isPantryStaple: (ingredient.value(forKey: "isPantryStaple") as? NSNumber)?.boolValue ?? false,
            aliases: aliases,
            rejectedMatchKeys: Self.stringArray(ingredient.value(forKey: "rejectedMatchKeys"))
        )
    }

    private func managedMatchRules(in root: NSManagedObject) -> [IngredientMatchRuleValue] {
        let rules = (root.value(forKey: "matchRules") as? NSSet)?.allObjects.compactMap { $0 as? NSManagedObject } ?? []
        return rules.compactMap { rule in
            guard let leftKey = rule.value(forKey: "leftKey") as? String,
                  let rightKey = rule.value(forKey: "rightKey") as? String,
                  let kindRaw = rule.value(forKey: "kindRaw") as? String,
                  let kind = IngredientMatchRuleKind(rawValue: kindRaw) else { return nil }
            return IngredientMatchRuleValue(leftKey: leftKey, rightKey: rightKey, kind: kind)
        }
    }

    private func planManagedRoutines(
        _ routines: [NSManagedObject],
        root: NSManagedObject,
        rootID: NSManagedObjectID,
        context: NSManagedObjectContext,
        through latestPlanningDate: Date?,
        memberName: String
    ) throws {
        let today = Date.now.startOfDay
        let defaultHorizon = today.adding(weeks: MealRoutineScheduler.horizonWeeks)
        let horizon = latestPlanningDate.map { min(defaultHorizon, $0.startOfDay) } ?? defaultHorizon
        guard horizon >= today else { return }

        let request = NSFetchRequest<NSManagedObject>(entityName: ManagedHouseholdEntity.mealPlanEntry.rawValue)
        request.predicate = NSPredicate(format: "household == %@ AND date >= %@ AND date < %@", root, today as NSDate, horizon.adding(days: 1) as NSDate)
        request.affectedStores = [try store(for: rootID)]
        let existingEntries = try context.fetch(request)
        func slotKey(_ date: Date, _ mealKey: String) -> String {
            "\(date.startOfDay.timeIntervalSinceReferenceDate)|\(mealKey)"
        }
        var occupied = Set<String>()
        var nextSortIndex: [String: Int] = [:]
        for entry in existingEntries {
            guard let date = entry.value(forKey: "date") as? Date,
                  let mealKey = entry.value(forKey: "mealSlotRaw") as? String else { continue }
            let key = slotKey(date, mealKey)
            occupied.insert(key)
            nextSortIndex[key] = max(
                nextSortIndex[key] ?? 0,
                ((entry.value(forKey: "sortIndex") as? NSNumber)?.intValue ?? -1) + 1
            )
        }

        let orderedRoutines = routines.sorted {
            let lhsDate = $0.value(forKey: "dateCreated") as? Date ?? .distantPast
            let rhsDate = $1.value(forKey: "dateCreated") as? Date ?? .distantPast
            if lhsDate != rhsDate { return lhsDate < rhsDate }
            return (($0.value(forKey: "uuid") as? UUID)?.uuidString ?? "") < (($1.value(forKey: "uuid") as? UUID)?.uuidString ?? "")
        }
        let managedDishes = (root.value(forKey: "dishes") as? NSSet)?.allObjects.compactMap { $0 as? NSManagedObject } ?? []
        let store = try store(for: rootID)

        for routine in orderedRoutines where (routine.value(forKey: "isActive") as? NSNumber)?.boolValue ?? false {
            guard let dishID = (routine.value(forKey: "dish") as? NSManagedObject)?.value(forKey: "uuid") as? UUID,
                  let dish = managedDishes.first(where: { $0.value(forKey: "uuid") as? UUID == dishID }),
                  let routineID = routine.value(forKey: "uuid") as? UUID else { continue }
            let mealKey = routine.value(forKey: "mealKey") as? String ?? MealSlot.dinner.rawValue
            let weekday = (routine.value(forKey: "weekday") as? NSNumber)?.intValue ?? 3
            let interval = (routine.value(forKey: "intervalWeeks") as? NSNumber)?.intValue ?? 1
            let startDate = routine.value(forKey: "startDate") as? Date ?? today
            let plannedThrough = routine.value(forKey: "plannedThrough") as? Date
            let from = max(today, plannedThrough?.adding(days: 1).startOfDay ?? today)
            guard from <= horizon else { continue }

            let projection = MealRoutine(dish: nil, mealKey: mealKey, weekday: weekday, intervalWeeks: interval, startDate: startDate)
            let days = projection.occurrences(from: from, through: horizon)
            for day in days {
                let key = slotKey(day, mealKey)
                guard occupied.insert(key).inserted else { continue }
                let entry = try insert(.mealPlanEntry, into: store, context: context)
                let now = Date.now
                entry.setValue(now, forKey: "placementModifiedAt")
                entry.setValue(now, forKey: "contentModifiedAt")
                entry.setValue(day.startOfDay, forKey: "date")
                entry.setValue(mealKey, forKey: "mealSlotRaw")
                entry.setValue(nextSortIndex[key] ?? 0, forKey: "sortIndex")
                entry.setValue(false, forKey: "skipped")
                entry.setValue(false, forKey: "prepReminder")
                entry.setValue(memberName, forKey: "plannedByName")
                entry.setValue(try JSONEncoder().encode([String]()), forKey: "participatingMemberUUIDs")
                entry.setValue(false, forKey: "isEatingOut")
                entry.setValue(routineID, forKey: "routineUUID")
                entry.setValue(dish, forKey: "dish")
                entry.setValue(root, forKey: "household")
                root.mutableSetValue(forKey: "entries").add(entry)
                nextSortIndex[key, default: 0] += 1
            }
            routine.setValue(horizon, forKey: "plannedThrough")
            routine.setValue(Date.now, forKey: "modifiedAt")
        }
    }

    private func managedIngredientModel(_ object: NSManagedObject) -> Ingredient? {
        guard let id = object.value(forKey: "uuid") as? UUID,
              let name = object.value(forKey: "name") as? String else { return nil }
        let category = IngredientCategory(rawValue: object.value(forKey: "categoryRaw") as? String ?? "") ?? .other
        let ingredient = Ingredient(name: name, category: category)
        ingredient.uuid = id
        ingredient.normalizedName = object.value(forKey: "normalizedName") as? String ?? Ingredient.normalize(name)
        ingredient.customAisleName = object.value(forKey: "customAisleName") as? String
        ingredient.isPantryStaple = (object.value(forKey: "isPantryStaple") as? NSNumber)?.boolValue ?? false
        ingredient.inventoryModeRaw = object.value(forKey: "inventoryModeRaw") as? String ?? InventoryMode.none.rawValue
        ingredient.inventoryCanonicalValue = (object.value(forKey: "inventoryCanonicalValue") as? NSNumber)?.doubleValue
        ingredient.inventoryDimensionRaw = object.value(forKey: "inventoryDimensionRaw") as? String
        ingredient.rejectedMatchKeys = Self.stringArray(object.value(forKey: "rejectedMatchKeys"))
        let aliasObjects = (object.value(forKey: "aliases") as? NSSet)?.allObjects.compactMap { $0 as? NSManagedObject } ?? []
        ingredient.aliases = aliasObjects.compactMap { object in
            guard let name = object.value(forKey: "name") as? String else { return nil }
            let source = IngredientAliasSource(rawValue: object.value(forKey: "sourceRaw") as? String ?? "") ?? .automatic
            let alias = IngredientAlias(name: name, source: source, confidence: (object.value(forKey: "confidence") as? NSNumber)?.doubleValue)
            alias.uuid = object.value(forKey: "uuid") as? UUID ?? alias.uuid
            alias.normalizedName = object.value(forKey: "normalizedName") as? String ?? Ingredient.normalize(name)
            alias.ingredient = ingredient
            return alias
        }
        return ingredient
    }

    private func insert(
        _ entity: ManagedHouseholdEntity,
        into store: NSPersistentStore,
        context: NSManagedObjectContext
    ) throws -> NSManagedObject {
        guard let description = NSEntityDescription.entity(forEntityName: entity.rawValue, in: context) else {
            throw ManagedHouseholdPersistenceError.entityMissing(entity)
        }
        let object = NSManagedObject(entity: description, insertInto: context)
        context.assign(object, to: store)
        object.setValue(UUID(), forKey: "uuid")
        object.setValue(Date.now, forKey: "modifiedAt")
        return object
    }

    private func finishManagedWrite(householdID: UUID, rootID: NSManagedObjectID) throws {
        if rootID.persistentStore === privateStore {
            try ManagedHouseholdRolloutAuthority.shared.recordManagedWrite(for: householdID)
        }
        NotificationCenter.default.post(name: .mealPlanManagedStoreDidChange, object: nil)
    }

    private func managedHouseholdObjectID(for householdID: UUID) throws -> NSManagedObjectID {
        let context = container.viewContext
        for store in [privateStore, sharedStore] {
            let request = NSFetchRequest<NSManagedObject>(entityName: ManagedHouseholdEntity.household.rawValue)
            request.predicate = NSPredicate(format: "uuid == %@", householdID as NSUUID)
            request.fetchLimit = 2
            request.affectedStores = [store]
            let matches = try context.fetch(request)
            guard matches.count <= 1 else {
                throw MealPlanManagedCollaborationError.duplicateStableIdentity
            }
            if let match = matches.first { return match.objectID }
        }
        throw MealPlanManagedCollaborationError.householdNotFound
    }

    func receive(_ metadata: CKShare.Metadata) async throws -> InvitationDeliveryDisposition {
        try await invitations.receive(metadata)
    }

    func storesDidLoad() async -> [InvitationProcessingResult] {
        await invitations.storesDidLoad()
    }

    func retryPendingInvitations() async -> [InvitationProcessingResult] {
        await invitations.processPendingInvitations()
    }

    func persistUpdatedShare(_ share: CKShare) async throws {
        try await sharing.persistUpdatedShare(share, in: privateStore)
    }

    private static func packageEnvironment(_ environment: CloudKitEnvironment) -> CollaborationEnvironment {
        switch environment {
        case .development: .development
        case .production: .production
        case .unknown: .unknown
        }
    }
}

@MainActor
private final class MealPlanShareRootResolver: ManagedShareRootResolving {
    private let context: NSManagedObjectContext
    private let privateStore: NSPersistentStore

    init(context: NSManagedObjectContext, privateStore: NSPersistentStore) {
        self.context = context
        self.privateStore = privateStore
    }

    func resolveObjectID(for rootID: String) throws -> NSManagedObjectID {
        guard let uuid = UUID(uuidString: rootID) else {
            throw MealPlanManagedCollaborationError.invalidHouseholdID
        }
        let request = NSFetchRequest<NSManagedObject>(entityName: ManagedHouseholdEntity.household.rawValue)
        request.predicate = NSPredicate(format: "uuid == %@", uuid as NSUUID)
        request.affectedStores = [privateStore]
        let matches = try context.fetch(request)
        guard matches.count == 1, let household = matches.first else {
            throw MealPlanManagedCollaborationError.householdNotFound
        }
        guard !household.objectID.isTemporaryID,
              household.objectID.persistentStore === privateStore,
              household.value(forKey: "uuid") as? UUID == uuid else {
            throw MealPlanManagedCollaborationError.invalidRootStore
        }
        return household.objectID
    }

    func shareBoundary(for rootID: String) -> ShareGraphBoundary {
        ShareGraphBoundary(rootID: rootID, scope: .workspace, identifier: rootID)
    }
}

private final class MealPlanShareGraphPreflight: ManagedSharePreflighting, @unchecked Sendable {
    private let container: NSPersistentCloudKitContainer
    private let privateStoreURL: URL

    init(container: NSPersistentCloudKitContainer, privateStore: NSPersistentStore) throws {
        guard let url = privateStore.url else {
            throw MealPlanManagedCollaborationError.managedStoresUnavailable
        }
        self.container = container
        privateStoreURL = url
    }

    func validateShareGraph(rootID: String, boundary: ShareGraphBoundary) async throws -> ShareGraphPreflightResult {
        guard boundary.scope == .workspace,
              boundary.rootID == rootID,
              boundary.identifier == rootID,
              UUID(uuidString: rootID) != nil else {
            throw MealPlanManagedCollaborationError.invalidHouseholdID
        }
        let context = container.newBackgroundContext()
        let privateStoreURL = self.privateStoreURL
        let count = try await context.perform {
            try Self.validate(rootID: rootID, context: context, privateStoreURL: privateStoreURL)
        }
        return ShareGraphPreflightResult(validatedObjectCount: count)
    }

    private static func validate(
        rootID: String,
        context: NSManagedObjectContext,
        privateStoreURL: URL
    ) throws -> Int {
        guard let householdID = UUID(uuidString: rootID) else {
            throw MealPlanManagedCollaborationError.invalidHouseholdID
        }
        let coordinator = context.persistentStoreCoordinator
        guard let privateStore = coordinator?.persistentStores.first(where: { $0.url == privateStoreURL }) else {
            throw MealPlanManagedCollaborationError.managedStoresUnavailable
        }
        let rootRequest = NSFetchRequest<NSManagedObject>(entityName: ManagedHouseholdEntity.household.rawValue)
        rootRequest.predicate = NSPredicate(format: "uuid == %@", householdID as NSUUID)
        rootRequest.affectedStores = [privateStore]
        let roots = try context.fetch(rootRequest)
        guard roots.count == 1, let root = roots.first else {
            throw MealPlanManagedCollaborationError.householdNotFound
        }

        let allowedEntities = Set(ManagedHouseholdEntity.allCases.map(\.rawValue))
        var pending = [root]
        var seen: Set<NSManagedObjectID> = []
        var seenUUIDsByEntity: [String: Set<UUID>] = [:]

        while let object = pending.popLast() {
            guard seen.insert(object.objectID).inserted else { continue }
            let entityName = object.entity.name ?? ""
            guard allowedEntities.contains(entityName) else {
                throw MealPlanManagedCollaborationError.unexpectedEntity
            }
            guard object.managedObjectContext === context,
                  object.objectID.persistentStore === privateStore,
                  object.objectID.persistentStore?.url == privateStoreURL else {
                throw MealPlanManagedCollaborationError.objectOutsidePrivateStore
            }
            guard let uuid = object.value(forKey: "uuid") as? UUID else {
                throw MealPlanManagedCollaborationError.missingStableIdentity
            }
            guard seenUUIDsByEntity[entityName, default: []].insert(uuid).inserted else {
                throw MealPlanManagedCollaborationError.duplicateStableIdentity
            }
            guard Self.householdID(for: object) == householdID else {
                throw MealPlanManagedCollaborationError.crossHouseholdRelationship
            }

            for relationship in object.entity.relationshipsByName.values {
                guard let value = object.value(forKey: relationship.name) else {
                    if Self.requiredRelationships[entityName, default: []].contains(relationship.name) {
                        throw MealPlanManagedCollaborationError.incompleteHouseholdGraph
                    }
                    continue
                }
                let related: [NSManagedObject]
                if relationship.isToMany {
                    if let set = value as? NSSet {
                        related = set.allObjects.compactMap { $0 as? NSManagedObject }
                    } else if let array = value as? [NSManagedObject] {
                        related = array
                    } else {
                        related = []
                    }
                } else if let object = value as? NSManagedObject {
                    related = [object]
                } else {
                    related = []
                }
                if related.isEmpty,
                   !relationship.isOptional,
                   Self.requiredRelationships[entityName, default: []].contains(relationship.name) {
                    throw MealPlanManagedCollaborationError.incompleteHouseholdGraph
                }
                pending.append(contentsOf: related)
            }
        }
        return seen.count
    }

    private static let requiredRelationships: [String: Set<String>] = [
        ManagedHouseholdEntity.dish.rawValue: ["household"],
        ManagedHouseholdEntity.dishImage.rawValue: ["dish"],
        ManagedHouseholdEntity.ingredient.rawValue: ["household"],
        ManagedHouseholdEntity.ingredientAlias.rawValue: ["ingredient"],
        ManagedHouseholdEntity.dishIngredient.rawValue: ["dish", "ingredient"],
        ManagedHouseholdEntity.mealPlanEntry.rawValue: ["household"],
        ManagedHouseholdEntity.mealRoutine.rawValue: ["household", "dish"],
        ManagedHouseholdEntity.shoppingListItem.rawValue: ["household"],
        ManagedHouseholdEntity.weekTemplate.rawValue: ["household"],
        ManagedHouseholdEntity.recipeFeed.rawValue: ["household"],
        ManagedHouseholdEntity.recipeFeedItem.rawValue: ["feed"],
    ]

    private static func householdID(for object: NSManagedObject) -> UUID? {
        if object.entity.name == ManagedHouseholdEntity.household.rawValue {
            return object.value(forKey: "uuid") as? UUID
        }
        if let household = object.value(forKey: "household") as? NSManagedObject {
            return household.value(forKey: "uuid") as? UUID
        }
        for relationshipName in ["dish", "ingredient", "template", "feed", "entry"] {
            guard let related = object.value(forKey: relationshipName) as? NSManagedObject else { continue }
            if related.entity.name == ManagedHouseholdEntity.household.rawValue {
                return related.value(forKey: "uuid") as? UUID
            }
            if let household = related.value(forKey: "household") as? NSManagedObject {
                return household.value(forKey: "uuid") as? UUID
            }
        }
        return nil
    }
}

enum MealPlanManagedCollaborationError: LocalizedError {
    case managedStoresUnavailable
    case invalidHouseholdID
    case householdNotFound
    case invalidRootStore
    case unexpectedEntity
    case objectOutsidePrivateStore
    case missingStableIdentity
    case duplicateStableIdentity
    case crossHouseholdRelationship
    case incompleteHouseholdGraph
    case editingNotAllowed

    var errorDescription: String? {
        switch self {
        case .managedStoresUnavailable: "Managed household sharing is not ready yet."
        case .invalidHouseholdID: "This household cannot be shared yet."
        case .householdNotFound: "The verified household was not found in the private store."
        case .invalidRootStore: "Only the canonical private household can be shared."
        case .unexpectedEntity: "The household contains an unsupported record type."
        case .objectOutsidePrivateStore: "The household graph includes data outside its private store."
        case .missingStableIdentity: "The household graph contains a record without a stable identity."
        case .duplicateStableIdentity: "The household graph contains duplicate record identities."
        case .crossHouseholdRelationship: "The household graph contains a link to another household."
        case .incompleteHouseholdGraph: "The household graph has an incomplete relationship."
        case .editingNotAllowed: "You do not have permission to change this household."
        }
    }
}

extension Notification.Name {
    static let mealPlanManagedCollaborationEvent = Notification.Name("MealPlan.ManagedCollaborationEvent")
}
