import SwiftUI

/// The one place that describes how MealPlan opens: a bistro awning of
/// alternating bands, the app's calendar-and-cutlery mark resting on the middle
/// one, and the whole thing lifting away to reveal the app.
///
/// **Seasonal repaint** — edit the two colour sets in
/// `MealPlan/Resources/Assets.xcassets`:
///
/// - `LaunchStripeInk` — the dark colour (ships as a deep navy)
/// - `LaunchStripeLinen` — the light colour (ships as a warm table-linen white)
///
/// Both the static launch screen (`Resources/LaunchScreen.storyboard`, which iOS
/// draws before a line of our code runs) and the animation below read those two
/// sets, so changing them repaints both and the handoff stays seamless.
///
/// Keep the *roles* when you repaint: ink is the dark one, linen the light one.
/// The mark is drawn in whichever of the two is not underneath it, so swapping
/// the roles rather than the hues would make it disappear.
enum LaunchTheme {
    static let ink = Color("LaunchStripeInk")
    static let linen = Color("LaunchStripeLinen")

    /// Bands of the awning, top to bottom. Deliberately **odd**: it puts a solid
    /// band under the centre of the screen, so the mark never straddles a seam.
    ///
    /// This number is mirrored in `LaunchScreen.storyboard` (as that many views
    /// in the stack view). Change one and you must change the other, or the
    /// system launch screen will visibly jump to a different first frame.
    static let stripeCount = 5

    /// The colour of one band, top to bottom: ink → linen → ink → …
    static func color(atStripe index: Int) -> Color {
        index.isMultiple(of: 2) ? ink : linen
    }

    /// The colour the mark is drawn in: always the opposite of the band it sits
    /// on, which for an odd `stripeCount` is band `stripeCount / 2`.
    static var markTint: Color {
        (stripeCount / 2).isMultiple(of: 2) ? linen : ink
    }

    // MARK: - Mark geometry
    //
    // These three numbers are duplicated as constraints on the image view in
    // LaunchScreen.storyboard. They exist so the animation's first frame lands
    // the mark in exactly the same place the system launch screen left it.

    /// Height ÷ width of `LaunchMark.svg`.
    static let markAspectRatio: CGFloat = 0.59437
    static let markWidthFraction: CGFloat = 0.42
    static let markMaxWidth: CGFloat = 260

    static func markWidth(in size: CGSize) -> CGFloat {
        min(size.width * markWidthFraction, markMaxWidth)
    }

    // MARK: - Motion

    enum Motion {
        /// The shortest the awning ever stays up, so the mark is readable even
        /// on an instant launch.
        ///
        /// iOS keeps its *own* copy of `LaunchScreen.storyboard` over the app
        /// until it judges the app to be up — which can be seconds after our
        /// layers exist. Our first frame is pixel-identical to that copy, so the
        /// handover is invisible; but anything we animate beforehand plays
        /// behind it and is simply never seen. `LaunchReadiness` waits that out;
        /// the four numbers below bound and tune the wait.
        static let minimumHold: Double = 0.45

        /// Give up waiting and lift anyway. A ceiling so an unusually slow
        /// launch can never strand the curtain on screen — and the reason the
        /// readiness check is allowed to be a heuristic at all.
        static let maximumHold: Double = 2

        /// How long a stretch of frames to judge the main thread on.
        static let frameRateWindow: Double = 0.3

        /// The fraction of the display's nominal frame rate that counts as
        /// "the app is up and keeping up". Deliberately forgiving: a launch
        /// still finishing its CloudKit and SwiftData work drops frames without
        /// being stalled, and waiting for a perfect cadence never fires.
        static let frameRateFloor: Double = 0.6

        /// How long a single band takes to clear the screen.
        static let bandTravel: Double = 0.58
        /// Each band starts this much after the one above it, so the awning
        /// peels away rather than sliding as one slab.
        static let bandStagger: Double = 0.045
        /// The mark fades first — it should be gone before the bands expose the
        /// app underneath.
        static let markFade: Double = 0.22
        /// Reduce Motion gets a plain cross-fade instead.
        static let reducedFade: Double = 0.18

        /// Extra distance each successive band travels, which spreads the bands
        /// apart on the way out instead of letting them exit as a block.
        static let bandTravelSpread: CGFloat = 22

        /// How long the lift itself takes, once it starts — the last band's
        /// stagger plus its travel.
        static func liftDuration(reduceMotion: Bool) -> Double {
            reduceMotion
                ? reducedFade
                : bandTravel + bandStagger * Double(LaunchTheme.stripeCount - 1)
        }
    }
}
