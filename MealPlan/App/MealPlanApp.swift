import SwiftUI
import SwiftData
#if canImport(UIKit)
import UIKit
import CloudKit
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
    #endif

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
                .environment(calendarStore)
                .task {
                    appState.bootstrap(context: container.mainContext)
                    await MealNotificationScheduler.shared.refreshFromStore(context: container.mainContext)
                    await calendarStore.start()
                }
                .onChange(of: scenePhase) { _, phase in
                    // Calendar access can be revoked while the app is away.
                    guard phase == .active else { return }
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
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        userDidAcceptCloudKitShareWith cloudKitShareMetadata: CKShare.Metadata
    ) {
        let container = CKContainer(identifier: SharedStore.cloudKitContainerID)
        container.accept(cloudKitShareMetadata) { _, error in
            if let error {
                NSLog("Failed to accept household share: \(error.localizedDescription)")
            }
        }
    }
}
#endif
