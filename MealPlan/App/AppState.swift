import CloudKit
import Foundation
import SwiftData
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Progress of deliberately joining a household — accepting an invitation.
/// The launch-time iCloud lookup never reports here: it runs silently behind
/// the device's own data (see `AppState.bootstrapFromCloud`).
enum CloudBootstrapState: Equatable {
    case connecting
    case downloading(Int)
    case importing(completed: Int, total: Int)
    case ready

    var isWorking: Bool {
        switch self {
        case .connecting, .downloading, .importing: true
        case .ready: false
        }
    }
}

/// App-wide UI state that isn't part of the synced model: which household is
/// active, the calendar's focused date, and the current library / shopping
/// filters.
@Observable
@MainActor
final class AppState {
    let cookingSession = CookingSessionStore.shared
    /// Durable projection of the current share participant. This replaces the
    /// old transient guest flag; it is restored before any network refresh.
    let collaboration = HouseholdCollaborationSession()
    var currentHousehold: Household?
    var selectedDate: Date = Date.now.startOfDay
    var dishFilter = DishFilter()
    /// The dish sidebar shown next to the plan filters independently of
    /// the Dishes section, so searching there doesn't disturb the library.
    var planDishFilter = DishFilter()
    var shoppingRange: ShoppingRangeOption = .thisWeek
    var shoppingCustomStart: Date = Date.now.startOfDay
    var shoppingCustomEnd: Date = Date.now.startOfDay.adding(days: 6)

    /// Compatibility name for older view code. New code should use
    /// `collaboration.canEdit` / `collaboration.role`.
    var isGuest: Bool { collaboration.isViewOnly }

    /// The section a deep link / App Intent wants shown.
    var requestedSection: AppSection?
    /// A recipe hand-off from Open Dish intent or a deep link.
    var requestedDishID: UUID?
    /// A pending "add dish" request from a deep link (the picker consumes it).
    var pendingAddDish: PendingAddDish?
    var importNotice: String?
    /// Set when the owner's single-use "add someone nearby" QR code opened
    /// the app; `RootView` presents `JoinNearbyHouseholdView` for it.
    var pendingNearbyJoin: NearbyJoinRequest?
    /// Covers the app while an accepted invitation downloads the household
    /// the person asked to join.
    var cloudBootstrapState: CloudBootstrapState = .ready
    /// True from launch until it is settled whether this device's household
    /// comes from iCloud. Nothing is shown for it — the device's own data is
    /// on screen the whole time — but syncing, the first-run tour and
    /// invitations wait for the answer rather than racing it.
    private(set) var isLookingForCloudHousehold = true
    /// Set once the lookup has actually found a household and is fetching it,
    /// so the first-run tour knows it is worth waiting for.
    private(set) var isDownloadingCloudHousehold = false
    /// A populated local household disagrees with another owned legacy zone.
    /// The migration window must preserve both graphs until recovery is chosen;
    /// this state is intentionally diagnostic/review-only.
    private(set) var legacyHouseholdRecovery: LegacyHouseholdRecoveryPlan = .noAction

    struct NearbyJoinRequest: Identifiable, Equatable {
        let id = UUID()
        var code: String?
    }

    struct PendingAddDish: Identifiable, Equatable {
        let id = UUID()
        var url: URL?
        var name: String?
    }

    /// Day cards the user collapsed on the plan, stored as `dayID` strings so
    /// the state survives the calendar's lazy scrolling and app launches.
    private(set) var collapsedDays: Set<String> = AppState.loadCollapsedDays()

    private static let collapsedDaysKey = "collapsedDayIDs"

    func isDayCollapsed(_ day: Date) -> Bool {
        collapsedDays.contains(day.dayID)
    }

    func setDayCollapsed(_ collapsed: Bool, for day: Date) {
        if collapsed {
            collapsedDays.insert(day.dayID)
        } else {
            collapsedDays.remove(day.dayID)
        }
        // Days that scrolled far into the past are never looked at again, so
        // drop them instead of growing the stored set forever.
        let cutoff = Date.now.adding(days: -60).dayID
        collapsedDays = collapsedDays.filter { $0 >= cutoff }
        UserDefaults.standard.set(Array(collapsedDays), forKey: Self.collapsedDaysKey)
    }

    private static func loadCollapsedDays() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: collapsedDaysKey) ?? [])
    }

    /// A transient "undo" offer shown after a forgiving destructive action.
    var undoOffer: UndoOffer?

    struct UndoOffer: Identifiable {
        let id = UUID()
        var message: String
        var action: () -> Void
    }

    func offerUndo(_ message: String, action: @escaping () -> Void) {
        undoOffer = UndoOffer(message: message, action: action)
    }

    /// The name to attribute new plans / edits to. It comes from the durable
    /// participant session whenever possible, rather than a device name.
    var currentMemberName: String {
        guard let snapshot = collaboration.snapshot,
              snapshot.memberID != nil || snapshot.participantID != nil else { return DeviceOwner.name }
        return snapshot.displayName
    }

    var unitSystem: UnitSystem {
        currentHousehold?.presentationUnitSystem ?? UnitConversion.system(for: .current)
    }

    var roundsDisplayedAmounts: Bool {
        currentHousehold?.roundsDisplayedAmounts ?? true
    }

    /// The portions this family cooks by default. Dish amounts are shown
    /// scaled to it unless the cook picks another head-count.
    var standardServings: Int {
        currentHousehold?.scalingServings ?? Household.defaultStandardServings
    }

    /// Whether estimated energy and macros appear anywhere in the app. A
    /// household can switch the whole thing off in Settings ▸ Nutrition.
    var showsNutritionEstimates: Bool {
        currentHousehold?.showsNutritionEstimates ?? true
    }

    var energyUnit: EnergyUnit {
        currentHousehold?.energyUnit ?? .kilocalories
    }

    /// An `AppState` wired to the seeded in-memory store, for previews.
    /// Deliberately not `#if DEBUG`: `#Preview` bodies compile in Release too,
    /// and `PreviewData` — which this is useless without — isn't gated either.
    static var preview: AppState {
        let state = AppState()
        state.bootstrap(context: PreviewData.container.mainContext)
        state.isLookingForCloudHousehold = false
        return state
    }

    /// Fetch the single household (creating it on first launch, with the
    /// default pantry staples) and run housekeeping that turns past plans into
    /// cooked-history.
    func bootstrap(context: ModelContext, planningThrough latestPlanningDate: Date? = nil) {
        var isNewHousehold = false
        if let existing = try? context.fetch(FetchDescriptor<Household>()).first {
            currentHousehold = existing
        } else {
            let household = Household(name: String(localized: "Family"))
            context.insert(household)
            try? context.save()
            currentHousehold = household
            isNewHousehold = true
        }
        if let household = currentHousehold {
            let migrationSucceeded = HouseholdCollaborationMigration.migrateIfNeeded()
            collaboration.restore(for: household)
            if !migrationSucceeded { collaboration.failClosedForUnknownMigrationFormat() }
            // Only a household this device just created: a family that has been
            // planning for a while must not have ingredients disappear off its
            // shopping list because of an update.
            if isNewHousehold {
                PantryStaples.seedDefaults(for: household, context: context)
            }
            MealType.ensure(for: household, context: context)
            CookedLogMaintenance.run(for: household, context: context)
            MealRoutineScheduler.apply(
                for: household,
                context: context,
                through: latestPlanningDate,
                memberName: currentMemberName
            )
            // Collections and dietary flags used to duplicate the tag system.
            // This is lossless, backed up first, and guarded per household.
            try? DishLabelConsolidation.migrateIfNeeded(household: household, context: context)
        }
        DishGlyphMaintenance.run(context: context)
        BlankDishMaintenance.run(context: context)
        cloudBootstrapState = .ready
    }

    /// Local first, iCloud behind it. The device's own household is set up
    /// and usable immediately; only when it is still empty — a new install,
    /// or a placeholder an older build created — does this go on to look for
    /// a household this Apple Account already has in iCloud, silently, and
    /// swap it in once it has been downloaded.
    ///
    /// Anything the person adds to the empty household in the meantime moves
    /// into the restored one (see `HouseholdCloudBootstrapService`), so using
    /// the app while the lookup runs costs nothing. A lookup that fails —
    /// offline, no iCloud account — is not reported: the app is already
    /// working, and the next launch looks again while the household is still
    /// empty.
    func bootstrapFromCloud(context: ModelContext, planningThrough latestPlanningDate: Date? = nil) async {
        let households = (try? context.fetch(FetchDescriptor<Household>())) ?? []
        let local = households.count == 1 ? households[0] : nil
        let shouldDiscover = households.isEmpty || (local.map(isReplaceableCloudPlaceholder) == true)

        bootstrap(context: context, planningThrough: latestPlanningDate)

        // Always inventory old owned zones, even once this device has content.
        // The previous empty-placeholder guard is what allowed two populated
        // same-account installations to silently remain split.
        await inspectLegacyHouseholds(context: context)

        guard shouldDiscover, let placeholder = currentHousehold else {
            isLookingForCloudHousehold = false
            return
        }
        isLookingForCloudHousehold = true
        defer {
            isLookingForCloudHousehold = false
            isDownloadingCloudHousehold = false
        }
        do {
            let restored = try await HouseholdCloudBootstrapService.restoreOwnedHouseholdIfAvailable(
                replacing: placeholder,
                context: context,
                progress: { [weak self] progress in
                    if progress != .lookingForHousehold { self?.isDownloadingCloudHousehold = true }
                }
            )
            if restored != nil {
                bootstrap(context: context, planningThrough: latestPlanningDate)
            }
        } catch {
            // Deliberately silent; see above.
        }
    }

    /// Re-runs the non-destructive legacy-zone inventory used by launch and by
    /// DEBUG diagnostics. It never changes the selected household itself.
    func inspectLegacyHouseholds(context: ModelContext) async {
        guard let household = currentHousehold else { return }

        // A participant's active household lives in the shared database and is
        // not part of this Apple Account's private owned-zone inventory. Never
        // offer to replace a joined household with an unrelated old private zone.
        if let locator = HouseholdShareLocator.decode(household.cloudKitShareIdentifier),
           !locator.isOwner {
            legacyHouseholdRecovery = .noAction
            return
        }

        do {
            let owned = try await HouseholdCloudBootstrapService.ownedHouseholdInventory()
            let plan = LegacyHouseholdRecoveryPlan.make(
                local: .init(household: household),
                owned: owned
            )
            legacyHouseholdRecovery = plan
            LegacyHouseholdDiagnostics.record(
                event: plan == .noAction ? "ownedZonesInventoried" : "ownedZoneRecoveryRequired",
                activeHouseholdID: household.uuid,
                owned: owned
            )
        } catch {
            LegacyHouseholdDiagnostics.record(
                event: "ownedZoneInventoryFailed",
                activeHouseholdID: household.uuid,
                error: error
            )
        }
    }

    /// Copies unmatched data from competing same-account legacy zones only
    /// after the settings UI has obtained the person's confirmation. The
    /// original CloudKit zones are retained; this is a reversible handoff,
    /// not a destructive automatic reconciliation.
    func reconcileLegacyHouseholds(context: ModelContext) async throws {
        cloudBootstrapState = .connecting
        defer { finishCloudDownload() }
        guard let local = currentHousehold else { return }
        if let locator = HouseholdShareLocator.decode(local.cloudKitShareIdentifier),
           !locator.isOwner {
            legacyHouseholdRecovery = .noAction
            return
        }
        let owned = try await HouseholdCloudBootstrapService.ownedHouseholdInventory()
        let plan = LegacyHouseholdRecoveryPlan.make(local: .init(household: local), owned: owned)
        guard case .reviewRequired(let canonicalID, _) = plan,
              let canonical = owned.first(where: { $0.householdID == canonicalID })
        else {
            legacyHouseholdRecovery = plan
            return
        }

        do {
            let recovered = try await HouseholdCloudBootstrapService.reconcileOwnedHouseholds(
                canonical: canonical,
                owned: owned,
                preserving: local,
                context: context,
                progress: updateCloudProgress
            )
            currentHousehold = recovered
            collaboration.restore(for: recovered)
            legacyHouseholdRecovery = .noAction
            LegacyHouseholdDiagnostics.record(
                event: "ownedZonesReconciled",
                activeHouseholdID: recovered.uuid,
                owned: owned
            )
        } catch {
            // `restoreOwnedHousehold` saves the canonical graph before it
            // starts copying unmatched competitor records. If a later local
            // save fails, point the UI at that saved graph rather than a
            // deleted pre-recovery object.
            if let recovered = (try? context.fetch(FetchDescriptor<Household>()))?.first(where: { $0.uuid == canonical.householdID }) {
                currentHousehold = recovered
                collaboration.restore(for: recovered)
            }
            LegacyHouseholdDiagnostics.record(
                event: "ownedZoneReconciliationFailed",
                activeHouseholdID: local.uuid,
                owned: owned,
                error: error
            )
            throw error
        }
    }

    func updateCloudProgress(_ progress: HouseholdCloudDownloadProgress) {
        switch progress {
        case .lookingForHousehold, .connecting: cloudBootstrapState = .connecting
        case .downloading(let count): cloudBootstrapState = .downloading(count)
        case .importing(let completed, let total):
            cloudBootstrapState = .importing(completed: completed, total: total)
        }
    }

    func finishCloudDownload() {
        cloudBootstrapState = .ready
    }

    private func isReplaceableCloudPlaceholder(_ household: Household) -> Bool {
        (household.dishes ?? []).isEmpty
            && (household.entries ?? []).isEmpty
            && (household.shoppingItems ?? []).isEmpty
            && (household.cookedLogs ?? []).isEmpty
            && (household.mealRoutines ?? []).isEmpty
            && (household.weekTemplates ?? []).isEmpty
            && (household.recipeFeeds ?? []).isEmpty
            && (household.recipeBookmarks ?? []).isEmpty
    }

    /// Route a `mealplan://` deep link (or an App Intent hand-off).
    func handle(_ link: DeepLink) {
        switch link {
        case .today:
            selectedDate = Date.now.startOfDay
            requestedSection = .plan
        case .date(let date):
            selectedDate = date.startOfDay
            requestedSection = .plan
        case .shoppingList:
            requestedSection = .shopping
        case .addDish(let url, let name):
            pendingAddDish = PendingAddDish(url: url, name: name)
            requestedSection = .dishes
        case .plan(let dishName, _, let date, _):
            if let date { selectedDate = date.startOfDay }
            if dishName != nil { pendingAddDish = PendingAddDish(url: nil, name: dishName) }
            requestedSection = .plan
        case .dish(let id):
            requestedDishID = id
            requestedSection = .dishes
        case .joinNearby(let code):
            // Adding someone nearby is iPhone and iPad only: the Mac app
            // ships without the local-network entitlement it would need.
            #if os(iOS)
            pendingNearbyJoin = NearbyJoinRequest(code: code)
            #else
            _ = code
            #endif
        }
    }

    func handle(url: URL) {
        if let link = DeepLink(url: url) { handle(link) }
    }

    /// Handles recipe archives opened from Files/Finder as well as the app's
    /// normal deep links. Recipes already in the library are skipped, and a
    /// second take on a dish you already have is imported as a variant rather
    /// than dropped, so re-opening the same backup is safe either way.
    func handle(openedURL url: URL, context: ModelContext) {
        // The system is meant to intercept iCloud share links itself and
        // call `AppDelegate`'s `userDidAcceptCloudKitShareWith`, but that
        // hand-off doesn't always happen (the link opened from inside
        // another app's browser, a chat app's link preview, or while
        // MealPlan is already frontmost). When that happens the URL reaches
        // here instead, and without this fallback the invitation would
        // silently do nothing on the recipient's phone.
        if HouseholdCloudSharingService.isShareURL(url) {
            Task {
                do {
                    let metadata = try await HouseholdCloudSharingService.fetchMetadata(for: url)
                    HouseholdShareInvitationInbox.shared.enqueue(metadata)
                } catch {
                    importNotice = String(localized: "Couldn’t open that invitation: \(error.localizedDescription)")
                }
            }
            return
        }
        guard RecipeFileType.isImportable(url) else {
            handle(url: url)
            return
        }
        requestedSection = .dishes
        Task { @MainActor in
            do {
                let recipes = try await Task.detached(priority: .userInitiated) {
                    try RecipeImportCommitter.recipes(fromFileAt: url)
                }.value
                let library = (try? context.fetch(FetchDescriptor<Dish>())) ?? []
                let plan = RecipeImportPlanner.plan(recipes, against: library)
                let result = await RecipeImportCommitter.commitResponsively(
                    plan,
                    household: currentHousehold,
                    createdByName: currentMemberName,
                    context: context
                )
                importNotice = result.summary
            } catch {
                importNotice = String(localized: "Couldn’t import that recipe archive: \(error.localizedDescription)")
            }
        }
    }
}

/// Best-effort human name for the person using this device.
enum DeviceOwner {
    @MainActor
    static var name: String {
        #if os(macOS)
        let full = Host.current().localizedName ?? ""
        if !full.isEmpty { return full }
        return NSFullUserName().isEmpty ? String(localized: "Me") : NSFullUserName()
        #else
        let device = UIDevice.current.name
        return device.isEmpty ? String(localized: "Me") : device
        #endif
    }
}
