import StoreKit
import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Owns the app-scene side of review requests. The shared ledger may be
/// updated by the Share Extension or an App Intent, but only this foreground
/// coordinator can invoke Apple's `RequestReviewAction`.
@MainActor
final class AppReviewPromptCoordinator {
    private let store: ReviewEngagementStore
    private let policy: ReviewEligibilityPolicy
    private let appVersion: String
    private let now: () -> Date
    private let cooldown: TimeInterval
    private let presentationDelay: Duration

    private var requestReview: (() -> Void)?
    private var isBusy: (() -> Bool)?
    private var activeScenes = Set<UUID>()
    private var scheduleGeneration = 0
    private var requestTask: Task<Void, Never>?

    init(
        store: ReviewEngagementStore = .live,
        policy: ReviewEligibilityPolicy = .standard,
        appVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
        now: @escaping () -> Date = { .now },
        cooldown: TimeInterval = ReviewEngagementStore.standardCooldown,
        presentationDelay: Duration = .seconds(5)
    ) {
        self.store = store
        self.policy = policy
        self.appVersion = appVersion
        self.now = now
        self.cooldown = cooldown
        self.presentationDelay = presentationDelay
    }

    func install(
        requestReview: @escaping () -> Void,
        isBusy: @escaping () -> Bool
    ) {
        self.requestReview = requestReview
        self.isBusy = isBusy
        scheduleIfAppropriate()
    }

    func sceneBecameActive(_ sceneID: UUID) {
        activeScenes.insert(sceneID)
        scheduleIfAppropriate()
    }

    func sceneBecameInactive(_ sceneID: UUID) {
        activeScenes.remove(sceneID)
        if activeScenes.isEmpty {
            scheduleGeneration += 1
            requestTask?.cancel()
            requestTask = nil
        }
    }

    /// Called after a placement notification. The delay lets a planning sheet
    /// dismiss and avoids presenting immediately from a Save action.
    func planningDidFinish() {
        scheduleIfAppropriate()
    }

    private func scheduleIfAppropriate() {
        guard !activeScenes.isEmpty, requestReview != nil else { return }
        scheduleGeneration += 1
        let generation = scheduleGeneration
        requestTask?.cancel()
        requestTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: presentationDelay)
            guard !Task.isCancelled,
                  generation == scheduleGeneration,
                  !activeScenes.isEmpty,
                  isBusy?() != true,
                  let requestReview
            else { return }

            let state = store.snapshot()
            guard state.pendingRequest || policy.isEligible(state),
                  policy.canAttempt(
                    state,
                    at: now(),
                    appVersion: appVersion,
                    cooldown: cooldown
                  ),
                  store.recordPromptAttempt(at: now(), appVersion: appVersion)
            else { return }

            // StoreKit decides whether a dialog is displayed. We record the
            // attempt before invoking it and never infer a review outcome.
            requestReview()
        }
    }
}

/// Mounts the coordinator at a SwiftUI scene boundary, where the native
/// `RequestReviewAction` environment value is available. There is no custom
/// UI or user-facing copy associated with this view.
@MainActor
struct AppReviewPromptHost<Content: View>: View {
    @Environment(\.requestReview) private var requestReview
    @Environment(\.scenePhase) private var scenePhase
    @State private var sceneID = UUID()

    let coordinator: AppReviewPromptCoordinator
    let isBusy: @MainActor () -> Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .onAppear {
                install()
                update(scenePhase)
            }
            .onDisappear {
                coordinator.sceneBecameInactive(sceneID)
            }
            .onChange(of: scenePhase) { _, phase in
                update(phase)
            }
            .onReceive(NotificationCenter.default.publisher(for: .reviewEngagementDidChange)) { _ in
                coordinator.planningDidFinish()
            }
    }

    private func install() {
        coordinator.install(
            requestReview: { requestReview() },
            isBusy: {
                isBusy() || Self.hasPresentedModalWindow
            }
        )
    }

    private func update(_ phase: ScenePhase) {
        switch phase {
        case .active:
            install()
            coordinator.sceneBecameActive(sceneID)
        case .inactive, .background:
            coordinator.sceneBecameInactive(sceneID)
        @unknown default:
            coordinator.sceneBecameInactive(sceneID)
        }
    }

    private static var hasPresentedModalWindow: Bool {
        #if canImport(UIKit)
        return UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
            .flatMap(\.windows)
            .contains { window in
                window.isKeyWindow && window.rootViewController?.presentedViewController != nil
            }
        #elseif os(macOS)
        return NSApp.keyWindow?.sheetParent != nil || NSApp.keyWindow?.attachedSheet != nil
        #else
        return false
        #endif
    }
}
