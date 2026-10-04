import CloudKit
import CoreData
import Foundation
import Testing
@testable import MealPlan

@MainActor
struct ManagedHouseholdPersistenceTests {
    @Test func opensPrivateAndSharedStoresWithoutCloudKit() async throws {
        let persistence = try ManagedHouseholdPersistence(cloudKitEnabled: false, inMemory: true)
        try await persistence.load()

        #expect(persistence.isLoaded)
        #expect(persistence.persistentStoreDescriptions.count == 2)

        let context = persistence.container.viewContext
        let householdID = UUID()
        let privateHousehold = try persistence.insert(.household, into: .private, context: context, uuid: householdID)
        let sharedHousehold = try persistence.insert(.household, into: .shared, context: context)
        try context.save()

        #expect(persistence.storeScope(for: privateHousehold) == .private)
        #expect(persistence.storeScope(for: sharedHousehold) == .shared)
        #expect(privateHousehold.value(forKey: "uuid") as? UUID == householdID)
        #expect(persistence.isEditable(privateHousehold))
        try persistence.setEditable(false, for: sharedHousehold)
        #expect(!persistence.isEditable(sharedHousehold))
    }

    @Test func preservesGraphRelationshipsAndExternalBinaryData() async throws {
        let persistence = try ManagedHouseholdPersistence(cloudKitEnabled: false, inMemory: true)
        try await persistence.load()
        let context = persistence.container.viewContext

        let householdID = UUID()
        let household = try persistence.insert(.household, into: .private, context: context, uuid: householdID)
        let dish = try persistence.insert(.dish, into: .private, context: context)
        let image = try persistence.insert(.dishImage, into: .private, context: context)
        let entry = try persistence.insert(.mealPlanEntry, into: .private, context: context)
        image.setValue(Data([0, 1, 2, 3]), forKey: "data")
        household.mutableSetValue(forKey: "dishes").add(dish)
        household.mutableSetValue(forKey: "entries").add(entry)
        dish.mutableSetValue(forKey: "images").add(image)
        entry.setValue(dish, forKey: "dish")
        try context.save()

        let request = NSFetchRequest<NSManagedObject>(entityName: ManagedHouseholdEntity.dishImage.rawValue)
        let images = try context.fetch(request)
        #expect(images.count == 1)
        #expect(images.first?.value(forKey: "data") as? Data == Data([0, 1, 2, 3]))
        #expect(persistence.storeScope(for: images[0]) == .private)

        context.delete(dish)
        try context.save()
        let entries = try context.fetch(NSFetchRequest<NSManagedObject>(entityName: ManagedHouseholdEntity.mealPlanEntry.rawValue))
        #expect(entries.count == 1)
        #expect(entries[0].value(forKey: "dish") == nil)

        context.delete(household)
        try context.save()
        #expect(try context.fetch(request).isEmpty)
    }

    @Test func declaresEveryCanonicalEntityAndKeepsCachesOutOfTheModel() {
        let persistence = try! ManagedHouseholdPersistence(cloudKitEnabled: false, inMemory: true)
        let names = Set(persistence.container.managedObjectModel.entities.compactMap(\.name))

        #expect(names == Set(ManagedHouseholdEntity.allCases.map(\.rawValue)))
        #expect(ManagedHouseholdPersistenceClassification.privateOrSharedHouseholdData == Set(ManagedHouseholdEntity.allCases))
        #expect(ManagedHouseholdPersistenceClassification.localOnlyCaches.contains("RecipeArticleCache"))
        #expect(!names.contains("RecipeArticleCache"))

        let dish = try! #require(persistence.container.managedObjectModel.entitiesByName["Dish"])
        let dishAttributes = Set(dish.attributesByName.keys)
        #expect(dishAttributes.isSuperset(of: ["uuid", "name", "tagNames", "statedFiberGramsPerServing", "translatedRecipeText"]))
        let householdAttributes = persistence.container.managedObjectModel.entitiesByName["Household"]?.attributesByName ?? [:]
        #expect(householdAttributes["cloudKitShareIdentifier"] == nil)
        let image = try! #require(persistence.container.managedObjectModel.entitiesByName["DishImage"])
        #expect(image.attributesByName["data"]?.allowsExternalBinaryDataStorage == true)
        let mergePolicy = try! #require(persistence.container.viewContext.mergePolicy as? NSMergePolicy)
        #expect(mergePolicy.mergeType == NSMergePolicyType.mergeByPropertyStoreTrumpMergePolicyType)
    }

    @Test func separatesDevelopmentAndProductionStoreURLs() throws {
        let directory = FileManager.default.temporaryDirectory
        let development = try ManagedHouseholdPersistence(
            storeDirectory: directory,
            cloudKitEnabled: false,
            environment: .development
        )
        let production = try ManagedHouseholdPersistence(
            storeDirectory: directory,
            cloudKitEnabled: false,
            environment: .production
        )

        let developmentURLs = Set(development.persistentStoreDescriptions.compactMap(\.url))
        let productionURLs = Set(production.persistentStoreDescriptions.compactMap(\.url))
        #expect(developmentURLs.isDisjoint(with: productionURLs))
    }

    @Test func configuresPrivateAndSharedCloudKitScopesWithoutLoadingTheStores() throws {
        let persistence = try ManagedHouseholdPersistence(
            storeDirectory: FileManager.default.temporaryDirectory,
            cloudKitEnabled: true,
            environment: .development
        )
        let descriptions = persistence.persistentStoreDescriptions
        let privateOptions = try #require(descriptions.first(where: { $0.configuration == "MealPlanManaged.Private" })?.cloudKitContainerOptions)
        let sharedOptions = try #require(descriptions.first(where: { $0.configuration == "MealPlanManaged.Shared" })?.cloudKitContainerOptions)

        #expect(privateOptions.containerIdentifier == SharedStore.cloudKitContainerID)
        #expect(sharedOptions.containerIdentifier == SharedStore.cloudKitContainerID)
        #expect(privateOptions.databaseScope == .private)
        #expect(sharedOptions.databaseScope == .shared)
    }
}
