import Foundation
import SwiftData

/// Keeps the family's shopping list and their Bring! list in step.
///
/// The rules live in `BringSyncPlan`; this is the part that reads the store,
/// talks to `BringClient` and writes the result back. It never throws away a
/// local line on its own: the worst a failed sync does is leave both lists
/// exactly as they were and put a sentence on screen.
@MainActor
@Observable
final class BringSyncService {

    static let shared = BringSyncService()

    private let client: BringClient

    /// A sync in flight, so the UI can show it and a second one can't start.
    private(set) var isSyncing = false

    init(client: BringClient = BringClient()) {
        self.client = client
    }

    /// What a sync did, for the sentence shown afterwards.
    struct Outcome: Equatable, Sendable {
        var sentToBring = 0
        var removedFromBring = 0
        var addedHere = 0
        var tickedOffHere = 0

        var isEmpty: Bool {
            sentToBring == 0 && removedFromBring == 0 && addedHere == 0 && tickedOffHere == 0
        }

        var summary: String {
            guard !isEmpty else { return String(localized: "Both lists were already the same.") }
            var parts: [String] = []
            if sentToBring > 0 { parts.append(String(localized: "\(sentToBring) sent to Bring!")) }
            if removedFromBring > 0 { parts.append(String(localized: "\(removedFromBring) taken off Bring!")) }
            if addedHere > 0 { parts.append(String(localized: "\(addedHere) added here")) }
            if tickedOffHere > 0 { parts.append(String(localized: "\(tickedOffHere) ticked off here")) }
            return parts.joined(separator: ", ")
        }
    }

    // MARK: - The account

    /// Whether this device has a Bring! account to sync with. Which list it
    /// syncs is on the household.
    var hasAccount: Bool { BringCredentialStore.load() != nil }

    var accountEmail: String? { BringCredentialStore.load()?.email }

    /// Sign in and report which lists the account can use, so one can be
    /// picked. The password is only written to the keychain once Bring! has
    /// accepted it.
    func signIn(email: String, password: String) async throws -> [BringList] {
        try await client.signIn(email: email, password: password)
        try BringCredentialStore.save(BringCredentials(email: email, password: password))
        return try await client.lists()
    }

    /// The lists of an account that is already signed in.
    func lists() async throws -> [BringList] {
        guard hasAccount else { throw BringError.notConnected }
        return try await client.lists()
    }

    /// Forget the account and the list. Nothing is removed from either
    /// shopping list — disconnecting is not a way to lose your groceries.
    func signOut(household: Household?, context: ModelContext) {
        BringCredentialStore.clear()
        Task { await client.signOut() }
        household?.bringListUuid = nil
        household?.bringListName = nil
        household?.bringShadowKeys = []
        household?.bringLastSyncedAt = nil
        try? context.save()
    }

    func use(_ list: BringList, household: Household, context: ModelContext) {
        household.bringListUuid = list.listUuid
        household.bringListName = list.name
        // A different list has a different history; start from a clean one so
        // the first sync merges rather than deletes.
        household.bringShadowKeys = []
        household.bringLastSyncedAt = nil
        try? context.save()
    }

    // MARK: - Syncing

    /// Send the whole list to Bring! and leave everything already there alone.
    /// The one-way version, for people who don't want MealPlan touching what
    /// Bring! holds.
    @discardableResult
    func push(household: Household, context: ModelContext) async throws -> Outcome {
        try await run(household: household, context: context) { local, remote, _ in
            BringSyncPlan.push(local: local, remote: remote)
        }
    }

    /// Reconcile both lists: adds go both ways, and anything either side has
    /// dropped since the last sync is dropped on the other.
    @discardableResult
    func sync(household: Household, context: ModelContext) async throws -> Outcome {
        try await run(household: household, context: context) { local, remote, shadow in
            BringSyncPlan.make(local: local, remote: remote, shadow: shadow)
        }
    }

    /// A sync that is nobody's explicit request — on opening the list, or
    /// after a rebuild. Silent about everything, including failure: an
    /// unreachable Bring! must not interrupt someone reading their list.
    func syncQuietly(household: Household, context: ModelContext) async {
        guard household.bringAutoSync, household.isConnectedToBring, hasAccount else { return }
        // Entering the Shopping tab repeatedly should be instant. Explicit
        // sync remains available at all times; automatic refresh is capped so
        // tab changes do not repeatedly fetch, rewrite, and save the list.
        if let last = household.bringLastSyncedAt, Date.now.timeIntervalSince(last) < 300 { return }
        _ = try? await sync(household: household, context: context)
    }

    private func run(
        household: Household,
        context: ModelContext,
        plan makePlan: @Sendable ([BringSyncItem], [BringSyncItem], [String]) -> BringSyncPlan
    ) async throws -> Outcome {
        guard let listUUID = household.bringListUuid, !listUUID.isEmpty else {
            throw BringError.noListChosen
        }
        guard hasAccount else { throw BringError.notConnected }
        guard !isSyncing else { return Outcome() }
        isSyncing = true
        defer { isSyncing = false }

        let local = localItems(of: household)
        let remote = try await client.purchases(in: listUUID).map {
            BringSyncItem(name: $0.itemId, specification: $0.specification ?? "")
        }
        let plan = makePlan(local, remote, household.bringShadowKeys)

        try await client.apply(plan.bringChanges, to: listUUID)
        apply(plan, to: household, context: context)

        return Outcome(
            sentToBring: plan.addToBring.count,
            removedFromBring: plan.removeFromBring.count,
            addedHere: plan.addLocally.count,
            tickedOffHere: plan.checkOffLocally.count
        )
    }

    // MARK: - The local half

    /// What is still to buy, as Bring! would see it. Ticked-off lines are
    /// bought, so as far as a sync is concerned they are already gone.
    private func localItems(of household: Household) -> [BringSyncItem] {
        (household.shoppingItems ?? [])
            .filter { !$0.isChecked }
            .map { BringSyncItem(name: $0.name, specification: $0.displayText ?? "") }
    }

    private func apply(_ plan: BringSyncPlan, to household: Household, context: ModelContext) {
        let items = household.shoppingItems ?? []

        for gone in plan.checkOffLocally {
            for item in items where IngredientMatching.key(for: item.name) == gone.key && !item.isChecked {
                item.isChecked = true
            }
        }

        let catalogue = household.ingredients ?? []
        for new in plan.addLocally {
            let ingredient = IngredientMatching.match(new.name, in: catalogue)
            // Manual, so the next rebuild from the plan leaves it alone: it
            // came from a person, in Bring!, not from a recipe.
            let item = ShoppingListItem(
                name: new.name,
                category: ingredient?.category ?? .other,
                isManual: true
            )
            item.household = household
            item.ingredient = ingredient
            item.customAisleName = ingredient?.customAisleName
            item.displayText = new.specification.isEmpty ? nil : new.specification
            item.sortIndex = item.category.sortOrder * 1000 + 999
            context.insert(item)
        }

        household.bringShadowKeys = plan.shadow
        household.bringLastSyncedAt = .now
        try? context.save()
    }
}
