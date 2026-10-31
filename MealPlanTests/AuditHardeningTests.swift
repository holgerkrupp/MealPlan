import Foundation
import Testing
@testable import MealPlan

struct AuditHardeningTests {
    private func makeDefaults() throws -> (UserDefaults, String) {
        let suite = "AuditHardeningTests.\(UUID().uuidString)"
        return (try #require(UserDefaults(suiteName: suite)), suite)
    }

    // MARK: - Links

    @Test func addDishLinkKeepsOnlyWebURLs() {
        let web = DeepLink(url: URL(string: "mealplan://add?url=https://example.com/r")!)
        guard case .addDish(let url, _) = web else { Issue.record("not addDish"); return }
        #expect(url?.host() == "example.com")

        let file = DeepLink(url: URL(string: "mealplan://add?url=file:///etc/hosts&name=X")!)
        guard case .addDish(let fileURL, let name) = file else { Issue.record("not addDish"); return }
        #expect(fileURL == nil)
        #expect(name == "X")
    }

    @Test func dishLinksRejectUnsafeSchemes() {
        let dish = Dish(name: "Soup")
        dish.sourceURLString = "tel:+491234"
        #expect(dish.sourceURL == nil)
        dish.sourceURLString = "https://example.com"
        #expect(dish.sourceURL != nil)

        dish.deepLinkURLString = "facetime:someone"
        #expect(dish.deepLinkURL == nil)
        dish.deepLinkURLString = "kptncook://recipe/1"
        #expect(dish.deepLinkURL != nil)
    }

    // MARK: - Downloads and images

    @Test func boundedDownloadRefusesNonWebSchemes() async {
        let request = URLRequest(url: URL(fileURLWithPath: "/etc/hosts"))
        await #expect(throws: RecipeImportError.self) { _ = try await BoundedDownload.data(for: request) }
    }

    @Test func nonImageBytesAreNotAPicture() {
        let bytes = Data("definitely not a picture".utf8)
        #expect(ImagePreparation.preparedImage(from: bytes) == nil)
        #expect(!ImagePreparation.isImage(bytes))
    }

    // MARK: - Account ownership

    @Test func householdStaysWithTheFirstAccount() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let id = UUID()
        #expect(HouseholdAccountOwnership.claim(householdID: id, environment: "prod", account: "A", defaults: defaults))
        #expect(HouseholdAccountOwnership.claim(householdID: id, environment: "prod", account: "A", defaults: defaults))
        #expect(!HouseholdAccountOwnership.claim(householdID: id, environment: "prod", account: "B", defaults: defaults))
        // Another environment is a separate identity for the same person.
        #expect(HouseholdAccountOwnership.claim(householdID: id, environment: "dev", account: "B", defaults: defaults))

        HouseholdAccountOwnership.assign(householdID: id, environment: "prod", account: "B", defaults: defaults)
        #expect(HouseholdAccountOwnership.claim(householdID: id, environment: "prod", account: "B", defaults: defaults))
    }

    // MARK: - Tombstones

    @Test func onlyOldAcknowledgedTombstonesArePruned() {
        let cutoff = Date(timeIntervalSince1970: 1_000)
        func tombstone(at seconds: TimeInterval) -> HouseholdSyncTombstone {
            HouseholdSyncTombstone(markerUUID: UUID(), deletedType: .dish, deletedUUID: UUID(), deletedAt: Date(timeIntervalSince1970: seconds))
        }
        let oldAcked = tombstone(at: 10)
        let oldUnacked = tombstone(at: 20)
        let recentAcked = tombstone(at: 2_000)
        var metadata = HouseholdSyncMetadata()
        metadata.tombstones = [oldAcked, oldUnacked, recentAcked]
        for acked in [oldAcked, recentAcked] {
            metadata.serverFingerprints[HouseholdRecordIdentity(type: .deletionMarker, uuid: acked.markerUUID).recordName] = "x"
        }

        #expect(metadata.pruneAcknowledgedTombstones(olderThan: cutoff) == 1)
        #expect(metadata.tombstones.map(\.markerUUID) == [oldUnacked.markerUUID, recentAcked.markerUUID])
    }

    // MARK: - Bring!

    @Test @MainActor func signingOutOfBringForgetsTheListOnlyWhenUnshared() throws {
        let household = Household(name: "Home")
        #expect(BringSyncService.signOutForgetsList(of: household))

        var shared = HouseholdShareLocator.solo(householdID: household.uuid)
        shared.shareRecordName = "share"
        household.cloudKitShareIdentifier = try HouseholdShareLocator.encode(shared)
        #expect(!BringSyncService.signOutForgetsList(of: household))
    }
}
