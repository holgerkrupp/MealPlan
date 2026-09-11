import Foundation
import Observation
import StoreKit

/// StoreKit 2 wrapper for MealPlan's single non-consumable unlock.
@MainActor
@Observable
final class PurchaseManager {
    static let shared = PurchaseManager()

    /// Configure this identifier as a non-consumable in App Store Connect.
    static let unlockProductID = "de.holgerkrupp.mealplan.unloc"

    static let paywallDisabled: Bool = {
        #if NO_PAYWALL
        return true
        #else
        return ProcessInfo.processInfo.environment["MEALPLAN_NO_PAYWALL"] == "1"
        #endif
    }()

    private(set) var product: Product?
    /// The unlock this device's Apple Account is entitled to by itself:
    /// bought with it, or shared with it through the App Store's Family
    /// Sharing. Never borrowed from a MealPlan household.
    private(set) var ownsUnlock = PurchaseEntitlementCache.isUnlocked
    /// The active household's synced `unlockedByPurchase` flag. Kept apart
    /// from `ownsUnlock` so switching households can drop the inherited
    /// unlock without disturbing a purchase this device actually made.
    private(set) var householdUnlock = false
    /// The household `reconcile(householdID:unlockedByPurchase:)` last ran
    /// against. A different id means the device joined another household.
    private(set) var reconciledHouseholdID: UUID?
    private(set) var purchaseInFlight = false
    private(set) var lastError: String?

    var isUnlocked: Bool { ownsUnlock || householdUnlock || Self.paywallDisabled }

    private var updatesTask: Task<Void, Never>?

    private init() {
        guard !Self.paywallDisabled else { return }
        updatesTask = Task { await listenForTransactions() }
        Task { await loadProduct() }
    }

    /// Refresh the locally available entitlement before features are gated.
    func prepareForLaunch() async {
        guard !Self.paywallDisabled else { return }
        await updateEntitlement()
    }

    func canPlan(on date: Date, now: Date = .now) -> Bool {
        PlanningAccess.canPlan(on: date, isUnlocked: isUnlocked, now: now)
    }

    /// Nil means there is no horizon; otherwise routines stop on this day.
    func latestPlanningDate(now: Date = .now) -> Date? {
        isUnlocked ? nil : PlanningAccess.latestFreeDate(now: now)
    }

    func loadProduct() async {
        do {
            product = try await Product.products(for: [Self.unlockProductID]).first
        } catch {
            lastError = error.localizedDescription
        }
    }

    func updateEntitlement() async {
        guard !Self.paywallDisabled else { return }
        var owned = false
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result,
               transaction.productID == Self.unlockProductID,
               transaction.revocationDate == nil,
               // Bought by this Apple Account, or shared with it by its App
               // Store family (the product is Family Shareable). Leaving the
               // family revokes the shared transaction, so it drops out here.
               [.purchased, .familyShared].contains(transaction.ownershipType) {
                owned = true
            }
        }
        setOwnsUnlock(owned)
    }

    @discardableResult
    func purchase() async -> Bool {
        if isUnlocked { return true }
        lastError = nil
        if product == nil {
            purchaseInFlight = true
            await loadProduct()
            purchaseInFlight = false
        }
        guard let product else {
            lastError = String(localized: "Couldn’t reach the App Store. Check your connection and try again.")
            return false
        }

        purchaseInFlight = true
        defer { purchaseInFlight = false }
        do {
            switch try await product.purchase() {
            case .success(.verified(let transaction)):
                await transaction.finish()
                setOwnsUnlock(true)
            case .success(.unverified(_, let error)):
                lastError = String(localized: "The purchase could not be verified: \(error.localizedDescription)")
            case .userCancelled, .pending:
                break
            @unknown default:
                break
            }
        } catch {
            lastError = error.localizedDescription
        }
        return isUnlocked
    }

    func restorePurchases() async {
        lastError = nil
        purchaseInFlight = true
        defer { purchaseInFlight = false }
        do {
            try await AppStore.sync()
            await updateEntitlement()
            if !isUnlocked {
                lastError = String(localized: "No previous purchase was found for this Apple Account.")
            }
        } catch {
            lastError = String(localized: "Purchases could not be restored: \(error.localizedDescription)")
        }
    }

    /// Point the entitlement at `householdID` and its synced unlock flag.
    ///
    /// When `householdID` differs from the household last reconciled against,
    /// the device has joined (or been reset onto) a different household: the
    /// inherited household unlock is dropped and this device's own App Store
    /// purchase is re-verified, so a paid device stays unlocked on its own
    /// merit while an unpaid one loses the unlock it borrowed from the old
    /// household. The household's own flag is then reflected into
    /// `householdUnlock`.
    func reconcile(householdID: UUID, unlockedByPurchase: Bool) async {
        guard !Self.paywallDisabled else { return }
        if reconciledHouseholdID != householdID {
            reconciledHouseholdID = householdID
            householdUnlock = false
            refreshEntitlementCache()
            await updateEntitlement()
        }
        setHouseholdUnlock(unlockedByPurchase)
    }

    private func setHouseholdUnlock(_ value: Bool) {
        guard householdUnlock != value else { return }
        householdUnlock = value
        refreshEntitlementCache()
    }

    private func setOwnsUnlock(_ value: Bool) {
        ownsUnlock = value
        refreshEntitlementCache()
    }

    /// The App Group cache the Share Extension reads carries the *effective*
    /// unlock — this device's purchase or the household's shared one.
    private func refreshEntitlementCache() {
        PurchaseEntitlementCache.isUnlocked = ownsUnlock || householdUnlock
    }

    private func listenForTransactions() async {
        for await result in Transaction.updates {
            if case .verified(let transaction) = result,
               transaction.productID == Self.unlockProductID {
                await transaction.finish()
                await updateEntitlement()
            }
        }
    }
}
