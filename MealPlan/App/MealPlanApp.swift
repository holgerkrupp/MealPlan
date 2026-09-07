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
    /// Where (if anywhere) the plan is published into a calendar. Created
    /// eagerly like the other stores above; it only acts once a destination
    /// has actually been chosen in Settings.
    @State private var publishedCalendarSettings = PublishedCalendarSettings()
    /// Writes the plan into that calendar via EventKit. A single shared
    /// instance so the whole app talks to the same `EKEventStore`.
    @State private var calendarEventWriter: any CalendarEventWriting = EventKitCalendarWriter()

    @Environment(\.scenePhase) private var scenePhase

    #if canImport(UIKit)
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #elseif os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif

    var body: some Scene {
        WindowGroup {
            // The awning comes down over the real interface, which is mounted
            // and doing its launch work underneath the whole time.
            AppLaunchContainerView {
                RootView()
                    .environment(appState)
                    .environment(calendarStore)
                    .environment(purchaseManager)
                    .environment(publishedCalendarSettings)
                    .environment(\.calendarEventWriter, calendarEventWriter)
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
                        PublishedCalendarService.scheduleRefreshIfNeeded(
                            household: appState.currentHousehold,
                            settings: publishedCalendarSettings,
                            context: container.mainContext,
                            writer: calendarEventWriter
                        )
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
                        PublishedCalendarService.scheduleRefreshIfNeeded(
                            household: appState.currentHousehold,
                            settings: publishedCalendarSettings,
                            context: container.mainContext,
                            writer: calendarEventWriter
                        )
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
                    .environment(publishedCalendarSettings)
                    .environment(\.calendarEventWriter, calendarEventWriter)
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
                .environment(publishedCalendarSettings)
                .environment(\.calendarEventWriter, calendarEventWriter)
                .modelContainer(container)
        }
        #endif
    }
}

#if canImport(UIKit)
/// Configures app and scene lifecycle hooks used by CloudKit sharing.
///
/// The legacy application callback remains as a fallback. Scene-based iOS
/// versions deliver invitations to `MealPlanSceneDelegate` below. Both only
/// queue the invitation — actually accepting it needs the `ModelContext` that
/// exists once SwiftUI has built the view hierarchy.
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

    /// CloudKit invitations are scene events in a scene-based app. SwiftUI
    /// doesn't install an app-owned scene delegate unless we explicitly
    /// provide one, so without this configuration iOS opens MealPlan after
    /// the system acceptance sheet but never delivers the share metadata.
    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        Self.sceneConfiguration(for: connectingSceneSession.role)
    }

    static func sceneConfiguration(for role: UISceneSession.Role) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(
            name: nil,
            sessionRole: role
        )
        if role == .windowApplication {
            configuration.delegateClass = MealPlanSceneDelegate.self
        }
        return configuration
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

/// Receives CloudKit invitations for SwiftUI's scene-based lifecycle.
///
/// UIKit uses two different paths: an already-connected window receives
/// `windowScene(_:userDidAcceptCloudKitShareWith:)`, while an invitation that
/// launches the app arrives in the new scene's connection options. Funnel
/// both through the in-memory inbox so `RootView` can accept them once its
/// SwiftData context is ready.
final class MealPlanSceneDelegate: UIResponder, UIWindowSceneDelegate {
    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        if let metadata = connectionOptions.cloudKitShareMetadata {
            HouseholdShareInvitationInbox.shared.enqueue(metadata)
        }
    }

    func windowScene(
        _ windowScene: UIWindowScene,
        userDidAcceptCloudKitShareWith cloudKitShareMetadata: CKShare.Metadata
    ) {
        HouseholdShareInvitationInbox.shared.enqueue(cloudKitShareMetadata)
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
