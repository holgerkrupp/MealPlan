#if canImport(ActivityKit) && os(iOS)
import ActivityKit
import SwiftUI
import WidgetKit

struct CookingTimerLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CookingActivityAttributes.self) { context in
            VStack(alignment: .leading, spacing: 8) {
                Label(String(localized: "Cooking timers"), systemImage: "frying.pan")
                    .font(.headline)
                ForEach(context.state.timers.prefix(3)) { timer in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(timer.contextLabel).font(.caption).foregroundStyle(.secondary)
                            Text(timer.timerLabel).font(.subheadline.weight(.semibold)).lineLimit(1)
                        }
                        Spacer()
                        remaining(timer)
                    }
                }
            }
            .padding()
            .activityBackgroundTint(.orange.opacity(0.16))
            .activitySystemActionForegroundColor(.orange)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "frying.pan.fill").foregroundStyle(.orange)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if let timer = context.state.timers.first { remaining(timer) }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(context.state.timers.prefix(2)) { timer in
                            Text("\(timer.contextLabel): \(timer.timerLabel)").lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } compactLeading: {
                Image(systemName: "timer").foregroundStyle(.orange)
            } compactTrailing: {
                if let timer = context.state.timers.first { remaining(timer) }
            } minimal: {
                Image(systemName: "timer").foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder
    private func remaining(_ timer: CookingActivityTimer) -> some View {
        if let paused = timer.pausedRemaining {
            Text(Duration.seconds(paused), format: .time(pattern: .minuteSecond))
                .monospacedDigit()
        } else {
            Text(timer.endDate, style: .timer)
                .monospacedDigit()
        }
    }
}
#endif
