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

    #if canImport(UIKit)
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
                .task {
                    appState.bootstrap(context: container.mainContext)
                    await MealNotificationScheduler.shared.refreshFromStore(context: container.mainContext)
                }
                .onOpenURL { url in
                    appState.handle(url: url)
                }
        }
        .modelContainer(container)
        #if os(macOS)
        Settings {
            NavigationStack {
                SettingsView()
            }
            .environment(appState)
            .modelContainer(container)
            .frame(width: 460, height: 520)
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
