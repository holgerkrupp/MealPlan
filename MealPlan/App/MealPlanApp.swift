import SwiftUI
import SwiftData
import CloudKit
#if canImport(UIKit)
import UIKit
#elseif os(macOS)
import AppKit
#endif

@main
struct MealPlanApp: App {
    let container = SharedStore.make(cloudKit: true)
    @State private var appState = AppState()
    @State private var purchaseManager = PurchaseManager.shared
    /// Calendar integration. Creating it touches no calendar data and never
    /// asks for permission — it only reads the (off by default) preference.
    @State private var calendarStore = CalendarContextStore()

    @Environment(\.scenePhase) private var scenePhase

    #if canImport(UIKit)
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #elseif os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
                .environment(calendarStore)
                .environment(purchaseManager)
                .task {
                    await purchaseManager.prepareForLaunch()
                    appState.bootstrap(
                        context: container.mainContext,
                        planningThrough: purchaseManager.latestPlanningDate()
                    )
                    MealPlanSpotlightIndexer.scheduleReindex(context: container.mainContext)
                    await MealNotificationScheduler.shared.refreshFromStore(context: container.mainContext)
                    await calendarStore.start()
                }
                .onReceive(NotificationCenter.default.publisher(for: .mealPlanDataDidChange)) { _ in
                    MealPlanSpotlightIndexer.scheduleReindex(context: container.mainContext)
                }
                .onChange(of: scenePhase) { _, phase in
                    // Calendar access can be revoked while the app is away.
                    guard phase == .active else { return }
                    MealPlanSpotlightIndexer.scheduleReindex(context: container.mainContext)
                    Task {
                        await calendarStore.applicationBecameActive()
                        if !appState.isGuest {
                            await RecipeFeedService.refreshAll(context: container.mainContext)
                        }
                    }
                }
                .onChange(of: purchaseManager.isUnlocked) { wasUnlocked, isUnlocked in
                    guard isUnlocked, !wasUnlocked, let household = appState.currentHousehold else { return }
                    MealRoutineScheduler.apply(
                        for: household,
                        context: container.mainContext,
                        memberName: appState.currentMemberName
                    )
                }
                .onOpenURL { url in
                    appState.handle(openedURL: url, context: container.mainContext)
                }
        }
        .modelContainer(container)
        .commands { MealPlanCommands() }
        #if os(macOS)
        WindowGroup("MealPlan", for: MacDetailWindowRoute.self) { $route in
            if let route {
                MacDetailWindow(route: route)
                    .environment(appState)
                    .environment(calendarStore)
                    .environment(purchaseManager)
            }
        }
        .defaultSize(width: 720, height: 760)
        .modelContainer(container)
        .commands { MealPlanCommands() }

        Settings {
            // SettingsView sizes its own window: it is a sidebar of panes, the
            // shape people expect from a macOS Settings window.
            SettingsView()
                .environment(appState)
                .environment(calendarStore)
                .environment(purchaseManager)
                .modelContainer(container)
        }
        #endif
    }
}

#if canImport(UIKit)
/// Handles CloudKit share acceptance (opening a "join our household" link).
///
/// Only queues the invitation — actually accepting it needs a `ModelContext`
/// to merge the shared household into, and that only exists once SwiftUI has
/// built the view hierarchy. See `HouseholdShareInvitationInbox` and
/// `RootView`'s drain of it.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        application.registerForRemoteNotifications()
        return true
    }

    func application(
        _ application: UIApplication,
        userDidAcceptCloudKitShareWith cloudKitShareMetadata: CKShare.Metadata
    ) {
        HouseholdShareInvitationInbox.shared.enqueue(cloudKitShareMetadata)
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        Task {
            await HouseholdRecordSyncService.shared.fetchChanges()
            completionHandler(.newData)
        }
    }
}
#elseif os(macOS)
/// macOS equivalent of the iOS `AppDelegate` hook above.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.registerForRemoteNotifications()
    }

    func application(_ application: NSApplication, userDidAcceptCloudKitShareWith cloudKitShareMetadata: CKShare.Metadata) {
        HouseholdShareInvitationInbox.shared.enqueue(cloudKitShareMetadata)
    }


    func application(_ application: NSApplication, didReceiveRemoteNotification userInfo: [String: Any]) {
        Task { await HouseholdRecordSyncService.shared.fetchChanges() }
    }
}
#endif
