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
                .task {
                    appState.bootstrap(context: container.mainContext)
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
                    Task { await calendarStore.applicationBecameActive() }
                }
                .onOpenURL { url in
                    appState.handle(openedURL: url, context: container.mainContext)
                }
        }
        .modelContainer(container)
        .commands { MealPlanCommands() }
        #if os(macOS)
        Settings {
            // SettingsView sizes its own window: it is a sidebar of panes, the
            // shape people expect from a macOS Settings window.
            SettingsView()
                .environment(appState)
                .environment(calendarStore)
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
        userDidAcceptCloudKitShareWith cloudKitShareMetadata: CKShare.Metadata
    ) {
        HouseholdShareInvitationInbox.shared.enqueue(cloudKitShareMetadata)
    }
}
#elseif os(macOS)
/// macOS equivalent of the iOS `AppDelegate` hook above.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, userDidAcceptCloudKitShareWith cloudKitShareMetadata: CKShare.Metadata) {
        HouseholdShareInvitationInbox.shared.enqueue(cloudKitShareMetadata)
    }
}
#endif
