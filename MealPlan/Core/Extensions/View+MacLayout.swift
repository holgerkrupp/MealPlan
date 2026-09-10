import SwiftUI

/// Layout the Mac asks for and the touch platforms don't.
///
/// A phone hands a view a safe area to sit inside; a resizable window hands it
/// nothing, so content written for iOS ends up flush against the window frame
/// and the traffic lights. These modifiers put the margin back — and only on
/// the platform that is missing it, so nothing about the iOS layout moves.
extension View {
    /// Breathing room between a scrolling surface and the window edges.
    ///
    /// `contentMargins` rather than `padding` on purpose: it insets what
    /// scrolls while leaving the scroll indicators — and any pinned header's
    /// background — running to the true edge, which is what a Mac window looks
    /// like.
    @ViewBuilder
    func macWindowMargins(
        _ edges: Edge.Set = .horizontal,
        _ amount: CGFloat = MacLayout.windowMargin
    ) -> some View {
        #if os(macOS)
        contentMargins(edges, amount, for: .scrollContent)
        #else
        self
        #endif
    }

    /// Breathing room for content that does not scroll.
    @ViewBuilder
    func macWindowPadding(
        _ edges: Edge.Set = .all,
        _ amount: CGFloat = MacLayout.windowMargin
    ) -> some View {
        #if os(macOS)
        padding(edges, amount)
        #else
        self
        #endif
    }
}

enum MacLayout {
    /// One margin for the whole app, so every window has the same gutter.
    static let windowMargin: CGFloat = 20

    /// The gutter between content and the edge of whatever holds it.
    ///
    /// A phone's screen edge is a hard boundary the eye reads as a frame, so
    /// 16 there looks generous; a resizable window sits on a desktop with no
    /// such boundary, and the same 16 looks like content that failed to fit.
    /// Every horizontal inset in the main screens goes through this, so the
    /// week strip, the plan, the dish grid and the shopping list all line up.
    static var gutter: CGFloat {
        #if os(macOS)
        windowMargin
        #else
        16
        #endif
    }
}
