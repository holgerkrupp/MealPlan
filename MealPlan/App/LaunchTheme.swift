import SwiftUI

/// The one place that describes how MealPlan opens: the full-colour app mark
/// resting on a matching warm background, then gently lifting away to reveal
/// the app.
///
/// Both the static launch screen (`Resources/LaunchScreen.storyboard`, which
/// iOS draws before a line of our code runs) and the animation below read the
/// same background and mark assets so their handoff stays seamless.
enum LaunchTheme {
    static let background = Color("LaunchBackground")

    // MARK: - Mark geometry
    //
    // These three numbers are duplicated as constraints on the image view in
    // LaunchScreen.storyboard. They exist so the animation's first frame lands
    // the mark in exactly the same place the system launch screen left it.

    /// Height ÷ width of the square `LaunchMark.png`.
    static let markAspectRatio: CGFloat = 1
    static let markWidthFraction: CGFloat = 0.56
    static let markMaxWidth: CGFloat = 280

    static func markWidth(in size: CGSize) -> CGFloat {
        min(size.width * markWidthFraction, markMaxWidth)
    }

    // MARK: - Motion

    enum Motion {
        /// The shortest the launch cover ever stays up, so the mark is readable even
        /// on an instant launch.
        ///
        /// iOS keeps its *own* copy of `LaunchScreen.storyboard` over the app
        /// until it judges the app to be up — which can be seconds after our
        /// layers exist. Our first frame is pixel-identical to that copy, so the
        /// handover is invisible; but anything we animate beforehand plays
        /// behind it and is simply never seen. `LaunchReadiness` waits that out;
        /// the four numbers below bound and tune the wait.
        static let minimumHold: Double = 0.45

        /// Give up waiting and fade anyway. A ceiling so an unusually slow
        /// launch can never strand the cover on screen — and the reason the
        /// readiness check is allowed to be a heuristic at all.
        static let maximumHold: Double = 2

        /// How long a stretch of frames to judge the main thread on.
        static let frameRateWindow: Double = 0.3

        /// The fraction of the display's nominal frame rate that counts as
        /// "the app is up and keeping up". Deliberately forgiving: a launch
        /// still finishing its CloudKit and SwiftData work drops frames without
        /// being stalled, and waiting for a perfect cadence never fires.
        static let frameRateFloor: Double = 0.6

        /// How long the icon and background take to fade away.
        static let markFade: Double = 0.3
        /// Reduce Motion gets a plain cross-fade instead.
        static let reducedFade: Double = 0.18

        /// How long the lift itself takes, once it starts.
        static func liftDuration(reduceMotion: Bool) -> Double {
            reduceMotion
                ? reducedFade
                : markFade
        }
    }
}
