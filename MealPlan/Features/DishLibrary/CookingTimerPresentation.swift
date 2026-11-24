import Foundation
import SwiftUI

/// The visual treatment used for cooking timers. The value is deliberately a
/// small, Codable-friendly enum so it can be persisted as a local preference
/// without becoming part of the cooking-session data shared with a household.
enum CookingTimerStyle: String, CaseIterable, Identifiable, Sendable {
    case native
    case segmented
    case circular

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .native: String(localized: "Native")
        case .segmented: String(localized: "Segmented Digital")
        case .circular: String(localized: "Circular")
        }
    }

    var description: String {
        switch self {
        case .native: String(localized: "Clean system-style countdown")
        case .segmented: String(localized: "Digital kitchen timer")
        case .circular: String(localized: "Progress ring with remaining time")
        }
    }
}

enum CookingTimerStylePreferences {
    static let storageKey = "CookingMode.timerStyle"
    static let defaultStyle: CookingTimerStyle = .native

    static func style(for rawValue: String) -> CookingTimerStyle {
        CookingTimerStyle(rawValue: rawValue) ?? defaultStyle
    }
}

enum CookingTimerFormatting {
    static func clockText(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval.rounded(.up)))
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let remainder = seconds % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, remainder)
            : String(format: "%02d:%02d", minutes, remainder)
    }

    static func status(for timer: CookingTimerState, at date: Date) -> String {
        if timer.remaining(at: date) <= 0 {
            return String(localized: "Completed")
        }
        return timer.pausedRemaining == nil
            ? String(localized: "Running")
            : String(localized: "Paused")
    }
}

/// A glanceable countdown that renders the same canonical timer state in one
/// of three visual styles. It owns no clock or timer mutation; `date` is the
/// presentation sample supplied by the cooking screen's TimelineView.
struct CookingTimerDisplay: View {
    let timer: CookingTimerState
    let date: Date
    let style: CookingTimerStyle

    private var remaining: TimeInterval { timer.remaining(at: date) }
    private var status: String { CookingTimerFormatting.status(for: timer, at: date) }
    private var accessibilityText: String {
        String(
            localized: "\(timer.label), \(CookingTimerFormatting.clockText(remaining)), \(status)"
        )
    }

    var body: some View {
        Group {
            switch style {
            case .native:
                nativeDisplay
            case .segmented:
                segmentedDisplay
            case .circular:
                circularDisplay
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityValue(status)
    }

    private var nativeDisplay: some View {
        VStack(spacing: 10) {
            Text(CookingTimerFormatting.clockText(remaining))
                .font(.system(.largeTitle, design: .monospaced).weight(.medium))
                .monospacedDigit()
                .minimumScaleFactor(0.65)
                .lineLimit(1)
            ProgressView(value: progress)
                .tint(timerTint)
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity)
    }

    private var segmentedDisplay: some View {
        VStack(spacing: 10) {
            SegmentedTimerDigits(text: CookingTimerFormatting.clockText(remaining), color: timerTint)
                .frame(height: 58)
                .frame(maxWidth: .infinity)
            ProgressView(value: progress)
                .tint(timerTint)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity)
    }

    private var circularDisplay: some View {
        ZStack {
            Circle()
                .stroke(.secondary.opacity(0.18), lineWidth: 10)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(timerTint, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 3) {
                Text(CookingTimerFormatting.clockText(remaining))
                    .font(.system(.title, design: .monospaced).weight(.semibold))
                    .monospacedDigit()
                    .minimumScaleFactor(0.65)
                    .lineLimit(1)
                Text(status)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 128, height: 128)
        .frame(maxWidth: .infinity)
    }

    private var progress: Double {
        guard timer.duration > 0 else { return remaining > 0 ? 1 : 0 }
        return min(1, max(0, remaining / timer.duration))
    }

    private var timerTint: Color {
        remaining <= 0 ? .red : (timer.pausedRemaining == nil ? .accentColor : .orange)
    }
}

private struct SegmentedTimerDigits: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(text.enumerated()), id: \.offset) { _, character in
                if character == ":" {
                    VStack(spacing: 8) {
                        Circle().fill(color).frame(width: 4, height: 4)
                        Circle().fill(color).frame(width: 4, height: 4)
                    }
                    .frame(width: 6, height: 50)
                } else if let digit = character.wholeNumberValue {
                    SevenSegmentDigit(value: digit, color: color)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

private struct SevenSegmentDigit: View {
    let value: Int
    let color: Color

    // top, upper-right, lower-right, bottom, lower-left, upper-left, middle
    private static let activeSegments: [[Bool]] = [
        [true, true, true, true, true, true, false],
        [false, true, true, false, false, false, false],
        [true, true, false, true, true, false, true],
        [true, true, true, true, false, false, true],
        [false, true, true, false, false, true, true],
        [true, false, true, true, false, true, true],
        [true, false, true, true, true, true, true],
        [true, true, true, false, false, false, false],
        [true, true, true, true, true, true, true],
        [true, true, true, true, false, true, true],
    ]

    var body: some View {
        let active = Self.activeSegments[value]
        VStack(spacing: 0) {
            segment(active[0], horizontal: true)
            HStack(spacing: 2) {
                segment(active[5], horizontal: false)
                Spacer(minLength: 0)
                segment(active[1], horizontal: false)
            }
            .frame(maxHeight: .infinity)
            segment(active[6], horizontal: true)
            HStack(spacing: 2) {
                segment(active[4], horizontal: false)
                Spacer(minLength: 0)
                segment(active[2], horizontal: false)
            }
            .frame(maxHeight: .infinity)
            segment(active[3], horizontal: true)
        }
        .frame(width: 28, height: 58)
    }

    private func segment(_ isActive: Bool, horizontal: Bool) -> some View {
        Capsule()
            .fill(isActive ? color : color.opacity(0.12))
            .frame(width: horizontal ? 23 : 3, height: horizontal ? 3 : 15)
    }
}

/// A compact visual selector used by the cooking-mode preferences sheet. Each
/// choice is a live preview, so selecting a style never requires guesswork.
struct CookingTimerStylePicker: View {
    @Binding var selection: CookingTimerStyle

    private let previewTimer = CookingTimerState(
        dishID: UUID(),
        dishName: String(localized: "Pasta"),
        stepNumber: 2,
        stepText: String(localized: "Simmer until tender"),
        label: String(localized: "Simmer"),
        duration: 780,
        endDate: Date(timeIntervalSince1970: 1_000 + 420)
    )

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(String(localized: "Timer appearance"))
                .font(.headline)
            Text(String(localized: "Choose how timers look in Cooking Mode. This preference stays on this device."))
                .font(.subheadline)
                .foregroundStyle(.secondary)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                ForEach(CookingTimerStyle.allCases) { style in
                    Button {
                        selection = style
                    } label: {
                        VStack(alignment: .leading, spacing: 10) {
                            CookingTimerDisplay(timer: previewTimer, date: Date(timeIntervalSince1970: 1_000), style: style)
                                .frame(height: 118)
                            Text(style.displayName)
                                .font(.headline)
                            Text(style.description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.leading)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            selection == style ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: 14)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 14)
                                .stroke(selection == style ? Color.accentColor : .clear, lineWidth: 2)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(style.displayName)
                    .accessibilityValue(selection == style ? String(localized: "Selected") : "")
                    .accessibilityHint(String(localized: "Changes the timer appearance immediately"))
                }
            }
        }
        .padding()
    }
}

/// A reusable timer card. All mutations are callbacks into the existing
/// CookingSessionStore, keeping cards independent even when labels and
/// durations happen to be identical.
struct CookingTimerCard: View {
    let timer: CookingTimerState
    let date: Date
    let style: CookingTimerStyle
    let isFocused: Bool
    let onPauseResume: () -> Void
    let onCancel: () -> Void
    let onFocus: () -> Void

    private var isComplete: Bool { timer.remaining(at: date) <= 0 }
    private var isPaused: Bool { timer.pausedRemaining != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(timer.contextLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Text(timer.label)
                        .font(.headline)
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                Button {
                    onFocus()
                } label: {
                    Image(systemName: isFocused ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel(isFocused
                    ? String(localized: "Show all timers")
                    : String(localized: "Focus timer"))
            }

            CookingTimerDisplay(timer: timer, date: date, style: style)

            HStack(spacing: 8) {
                Label(CookingTimerFormatting.status(for: timer, at: date), systemImage: statusSymbol)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(statusColor)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Button(isComplete ? String(localized: "Dismiss") : (isPaused ? String(localized: "Resume") : String(localized: "Pause")), systemImage: isComplete ? "checkmark" : (isPaused ? "play.fill" : "pause.fill")) {
                    if isComplete {
                        onCancel()
                    } else {
                        onPauseResume()
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                Button(String(localized: "Cancel"), systemImage: "xmark") {
                    onCancel()
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .accessibilityLabel(String(localized: "Cancel timer"))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .stroke(isFocused ? Color.accentColor.opacity(0.7) : .clear, lineWidth: 2)
        }
        .accessibilityElement(children: .contain)
        .accessibilityHint(String(localized: "Use Focus timer to enlarge this timer"))
    }

    private var statusSymbol: String {
        isComplete ? "checkmark.circle.fill" : (isPaused ? "pause.circle.fill" : "play.circle.fill")
    }

    private var statusColor: Color {
        isComplete ? .red : (isPaused ? .orange : .accentColor)
    }
}

/// Adaptive multi-timer presentation for the persistent bottom summary in
/// Cooking Mode. A focused timer gets a full-width card while every other
/// timer remains visible below it.
struct CookingTimerSummary: View {
    let timers: [CookingTimerState]
    let date: Date
    let style: CookingTimerStyle
    @Binding var focusedTimerID: UUID?
    let onPauseResume: (UUID) -> Void
    let onCancel: (UUID) -> Void
    let onAddTimer: () -> Void

    private var focusedTimer: CookingTimerState? {
        guard let focusedTimerID else { return nil }
        return timers.first { $0.id == focusedTimerID }
    }

    private var otherTimers: [CookingTimerState] {
        guard let focusedTimerID else { return timers }
        return timers.filter { $0.id != focusedTimerID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label(String(localized: "Cooking timers"), systemImage: "timer")
                    .font(.headline)
                Text(String(localized: "\(timers.count) timers"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button(String(localized: "Add timer"), systemImage: "plus") {
                    onAddTimer()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if let focusedTimer {
                CookingTimerCard(
                    timer: focusedTimer,
                    date: date,
                    style: style,
                    isFocused: true,
                    onPauseResume: { onPauseResume(focusedTimer.id) },
                    onCancel: { onCancel(focusedTimer.id) },
                    onFocus: { focusedTimerID = nil }
                )
            }

            if !otherTimers.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 12)], spacing: 12) {
                    ForEach(otherTimers) { timer in
                        CookingTimerCard(
                            timer: timer,
                            date: date,
                            style: style,
                            isFocused: false,
                            onPauseResume: { onPauseResume(timer.id) },
                            onCancel: { onCancel(timer.id) },
                            onFocus: { focusedTimerID = timer.id }
                        )
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

#Preview("Timer styles") {
    CookingTimerStylePreview()
}

private struct CookingTimerStylePreview: View {
    @State private var style = CookingTimerStyle.native
    private let timer = CookingTimerState(
        dishID: UUID(),
        dishName: "Pasta",
        stepNumber: 1,
        stepText: "Cook",
        label: "Cook",
        duration: 600,
        endDate: Date(timeIntervalSince1970: 1_300)
    )

    var body: some View {
        VStack(spacing: 20) {
            CookingTimerStylePicker(selection: $style)
            CookingTimerCard(
                timer: timer,
                date: Date(timeIntervalSince1970: 1_000),
                style: style,
                isFocused: true,
                onPauseResume: {},
                onCancel: {},
                onFocus: {}
            )
        }
        .padding()
    }
}
