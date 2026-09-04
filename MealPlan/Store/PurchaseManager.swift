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
    private(set) var ownsUnlock = PurchaseEntitlementCache.isUnlocked
    private(set) var purchaseInFlight = false
    private(set) var lastError: String?

    var isUnlocked: Bool { ownsUnlock || Self.paywallDisabled }

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
               transaction.revocationDate == nil {
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

    private func setOwnsUnlock(_ value: Bool) {
        ownsUnlock = value
        PurchaseEntitlementCache.isUnlocked = value
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
