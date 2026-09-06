import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Wraps the app's real interface and holds a copy of the launch screen over it
/// until the opening animation has played.
///
/// The interface underneath is mounted and doing its launch work from the first
/// frame — the curtain is decoration over the top and never takes a touch — so
/// the animation costs nothing but the time it takes to look at.
@MainActor
struct AppLaunchContainerView<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let content: Content

    @State private var phase: Phase = .holding

    private enum Phase {
        /// Showing the awning, waiting for the app to actually be on screen.
        case holding
        /// The awning is on its way out.
        case lifting
        /// Gone; the curtain is no longer in the hierarchy.
        case gone
    }

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ZStack {
            content

            if phase != .gone {
                AnimatedLaunchView(isFinishing: phase == .lifting, reduceMotion: reduceMotion)
                    // Full-bleed, like the launch screen it continues from —
                    // without this the curtain is inset by the safe area and
                    // the handover shows a band of app around the edges.
                    .ignoresSafeArea()
                    .zIndex(1)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                    .task { await lift() }
            }
        }
    }

    private func lift() async {
        await LaunchReadiness.waitUntilAppIsOnScreen()
        phase = .lifting
        try? await Task.sleep(for: .seconds(LaunchTheme.Motion.liftDuration(reduceMotion: reduceMotion)))
        phase = .gone
    }
}

// MARK: - Knowing when the app is actually in front of the user

enum LaunchReadiness {
    /// Returns once the app is on screen and settled.
    ///
    /// iOS keeps *its own* copy of `LaunchScreen.storyboard` over the app until
    /// it judges the app to be up, and offers no notification when it lets go.
    /// Our first frame is pixel-identical to that copy, so the handover is
    /// invisible — but anything animated beforehand plays behind it and is
    /// simply never seen. Measured at roughly three seconds on a debug
    /// simulator build and a fraction of that in release, which is exactly why
    /// a fixed delay cannot serve both.
    ///
    /// There is a usable tell, though: while launch work still owns the main
    /// thread the display link only gets serviced sporadically, and the frame
    /// rate climbs back to near-nominal once the app is up — which is about
    /// when the system hands the screen over. So we wait for the main thread to
    /// be keeping up, floored by `minimumHold` so the mark is readable even on
    /// an instant launch, and capped by `maximumHold` so a slow one cannot
    /// strand the curtain.
    ///
    /// It is a heuristic, and the cap is what makes it safe: the worst case is
    /// that the lift starts a little early and the user sees the tail of it
    /// rather than the whole thing, which still reads correctly.
    static func waitUntilAppIsOnScreen() async {
        #if canImport(UIKit)
        await SteadyFrameWatcher().waitUntilSettled()
        #else
        // No system launch screen on macOS; just hold long enough to read.
        try? await Task.sleep(for: .seconds(LaunchTheme.Motion.minimumHold))
        #endif
    }
}

#if canImport(UIKit)

@MainActor
private final class SteadyFrameWatcher {
    private var displayLink: CADisplayLink?
    private var began: CFTimeInterval = 0
    /// Tick times inside the sampling window, oldest first.
    private var recentTicks: [CFTimeInterval] = []
    private var resume: (() -> Void)?

    func waitUntilSettled() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            resume = { continuation.resume() }
            began = CACurrentMediaTime()
            let link = CADisplayLink(target: self, selector: #selector(tick))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        let frameDuration = link.targetTimestamp - link.timestamp
        let window = LaunchTheme.Motion.frameRateWindow

        recentTicks.append(now)
        recentTicks.removeAll { now - $0 > window }

        // Ticks we would have got over this window if nothing were dropped.
        let expected = window / max(frameDuration, .ulpOfOne)
        let keepingUp = Double(recentTicks.count) >= expected * LaunchTheme.Motion.frameRateFloor

        let waited = now - began
        let settled = waited >= LaunchTheme.Motion.minimumHold
            && waited >= window
            && keepingUp
        guard settled || waited >= LaunchTheme.Motion.maximumHold else { return }

        link.invalidate()
        displayLink = nil
        resume?()
        resume = nil
    }
}

#endif

// MARK: - The awning

/// The launch screen, and the animation that takes it away.
///
/// Pass `isFinishing: false` to render it standing still — that state is
/// pixel-identical to `LaunchScreen.storyboard`, which is what makes the
/// handover from the system launch screen invisible.
@MainActor
struct AnimatedLaunchView: View {
    let isFinishing: Bool
    var reduceMotion = false

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let markWidth = LaunchTheme.markWidth(in: size)

            ZStack {
                awning(in: size)

                Image("LaunchMark")
                    .resizable()
                    .renderingMode(.template)
                    .foregroundStyle(LaunchTheme.markTint)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: markWidth, height: markWidth * LaunchTheme.markAspectRatio)
                    // The mark clears out before the bands part, so it never
                    // appears to float over the app underneath.
                    .opacity(isFinishing ? 0 : 1)
                    .scaleEffect(isFinishing ? 0.96 : 1)
                    .animation(.easeOut(duration: LaunchTheme.Motion.markFade), value: isFinishing)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // Deliberately no background: the bands are the only thing covering the
        // app, so lifting them is what reveals it. They are sized to overlap
        // rather than tile, which is what keeps a hairline from ever showing
        // through while they are down.
        //
        // Reduce Motion gets a plain cross-fade instead of the lift.
        .opacity(reduceMotion && isFinishing ? 0 : 1)
        .animation(
            reduceMotion ? .easeOut(duration: LaunchTheme.Motion.reducedFade) : nil,
            value: isFinishing
        )
        .ignoresSafeArea()
    }

    private func awning(in size: CGSize) -> some View {
        let count = LaunchTheme.stripeCount
        let seam = size.height / CGFloat(count)
        // Round the band up so neighbours overlap by a fraction of a point
        // rather than leaving a hairline of background between them.
        let bandHeight = seam.rounded(.up)

        return ZStack(alignment: .top) {
            ForEach(0..<count, id: \.self) { index in
                Rectangle()
                    .fill(LaunchTheme.color(atStripe: index))
                    .frame(width: size.width, height: bandHeight)
                    .offset(y: CGFloat(index) * seam + travel(for: index, in: size))
                    .animation(
                        reduceMotion
                            ? nil
                            : .easeIn(duration: LaunchTheme.Motion.bandTravel)
                                .delay(Double(index) * LaunchTheme.Motion.bandStagger),
                        value: isFinishing
                    )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .clipped()
    }

    /// How far a band has to travel to clear the top of the screen. Later bands
    /// go a little further, which spreads the awning out on the way up instead
    /// of letting it leave as one slab.
    private func travel(for index: Int, in size: CGSize) -> CGFloat {
        guard isFinishing, !reduceMotion else { return 0 }
        return -size.height - CGFloat(index) * LaunchTheme.Motion.bandTravelSpread
    }
}

#Preview("Launch screen") {
    AnimatedLaunchView(isFinishing: false)
}
