import Foundation
import Testing
@testable import MealPlan

#if os(iOS)
struct ShareHandoffTests {

    @Test @MainActor func queueSurvivesUntilTheRouteAcknowledgesIt() {
        let url = URL(string: "https://example.com/recipe")!
        #expect(ShareHandoff.store(.site(url)))
        defer {
            if let pending = ShareHandoff.pending() {
                ShareHandoff.consume(id: pending.id)
            }
        }

        let state = AppState()
        state.markReadyForShareHandoff()

        #expect(state.pendingSharedSiteURL == url)
        #expect(state.requestedSection == .dishes)
        #expect(ShareHandoff.pending() != nil)

        state.acknowledgePendingShareHandoffRoute()
        #expect(ShareHandoff.pending() == nil)
    }

    @Test @MainActor func aColdStateDoesNotConsumeBeforeItIsReady() {
        let url = URL(string: "https://example.com/recipe")!
        #expect(ShareHandoff.store(.site(url)))
        defer {
            if let pending = ShareHandoff.pending() {
                ShareHandoff.consume(id: pending.id)
            }
        }

        let state = AppState()
        state.acceptPendingShareHandoff()

        #expect(state.pendingSharedSiteURL == nil)
        #expect(ShareHandoff.pending() != nil)
    }

    @Test @MainActor func staleAcknowledgementCannotConsumeAReplacement() {
        let firstURL = URL(string: "https://example.com/first")!
        let secondURL = URL(string: "https://example.com/second")!
        #expect(ShareHandoff.store(.site(firstURL)))
        defer {
            if let pending = ShareHandoff.pending() {
                ShareHandoff.consume(id: pending.id)
            }
        }

        let first = try! #require(ShareHandoff.pending())
        #expect(ShareHandoff.store(.site(secondURL)))
        ShareHandoff.consume(id: first.id)

        let current = try! #require(ShareHandoff.pending())
        #expect(current.id != first.id)
        if case .site(let url) = current.destination {
            #expect(url == secondURL)
        } else {
            Issue.record("expected site destination")
        }
    }
}
#endif
