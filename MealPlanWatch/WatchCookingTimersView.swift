import SwiftUI

/// The watch's own glanceable cooking surface. The timer values come from the
/// phone snapshot; TimelineView only redraws the local presentation.
struct WatchCookingTimersView: View {

    @Environment(WatchDataStore.self) private var store

    private var timers: [WatchCookingTimer] {
        store.snapshot.cookingTimers?.timers ?? []
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            Group {
                if let session = store.snapshot.cookingSession {
                    List {
                        WatchCookingSessionOverview(session: session, now: timeline.date)
                    }
                } else if timers.isEmpty {
                    WatchEmptyState(
                        symbol: "timer",
                        title: String(localized: "No cooking timers"),
                        message: String(localized: "Start a timer in Cooking Mode on iPhone.")
                    )
                } else {
                    List {
                        if let feedback = store.timerCommandFeedback {
                            WatchTimerFeedbackView(feedback: feedback)
                        }

                        Section {
                            ForEach(timers) { timer in
                                WatchCookingTimerRow(timer: timer, now: timeline.date)
                            }
                        } header: {
                            Text(String(localized: "\(timers.count) cooking timers"))
                        }

                        WatchSyncFooter()
                    }
                }
            }
        }
        .navigationTitle(String(localized: "Cooking"))
    }
}

private struct WatchCookingSessionOverview: View {

    @Environment(WatchDataStore.self) private var store
    let session: WatchCookingSessionSnapshot
    let now: Date

    private var selectedDish: WatchCookingDish? { session.selectedDish }
    private var selectedStepPending: Bool {
        store.isCookingCommandPending(for: selectedDish?.id)
    }

    @ViewBuilder
    var body: some View {
        Section {
            if let dish = selectedDish {
                VStack(alignment: .leading, spacing: 8) {
                    Label(dish.name, systemImage: "fork.knife")
                        .font(.headline)
                        .lineLimit(2)
                    if let stepText = dish.currentStepText {
                        Text(stepText)
                            .font(.body)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text(String(localized: "This recipe has no cooking steps yet."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(
                        dish.steps.isEmpty
                            ? String(localized: "No steps")
                            : String(localized: "Step \(dish.currentStep + 1) of \(dish.steps.count)")
                    )
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(String(localized: "Current step"))
                    .accessibilityValue(
                        dish.steps.isEmpty
                            ? String(localized: "No steps")
                            : String(localized: "Step \(dish.currentStep + 1) of \(dish.steps.count)")
                    )
                }
                .accessibilityElement(children: .combine)

                HStack(spacing: 8) {
                    Button {
                        store.sendCookingCommand(
                            action: .setStep(
                                dishID: dish.id,
                                step: max(0, dish.currentStep - 1)
                            )
                        )
                    } label: {
                        Label(String(localized: "Previous"), systemImage: "chevron.left")
                    }
                    .disabled(dish.currentStep <= 0 || selectedStepPending)

                    Button {
                        store.sendCookingCommand(
                            action: .setStep(
                                dishID: dish.id,
                                step: min(dish.steps.count - 1, dish.currentStep + 1)
                            )
                        )
                    } label: {
                        Label(String(localized: "Next"), systemImage: "chevron.right")
                    }
                    .disabled(
                        dish.steps.isEmpty ||
                        dish.currentStep >= dish.steps.count - 1 ||
                        selectedStepPending
                    )
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityElement(children: .contain)
            } else {
                Label(
                    String(localized: "Recipe unavailable"),
                    systemImage: "exclamationmark.triangle"
                )
            }

            Button {
                store.sendCookingCommand(action: .handoff)
            } label: {
                Label(String(localized: "Refresh from iPhone"), systemImage: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(.bordered)
            .disabled(store.isCookingCommandPending())
        } header: {
            Text(String(localized: "Cooking session"))
        }

        if session.dishes.count > 1 {
            Section(String(localized: "Dishes")) {
                ForEach(session.dishes) { dish in
                    Button {
                        store.sendCookingCommand(action: .selectDish(dish.id))
                    } label: {
                        HStack {
                            Text(dish.name)
                                .lineLimit(2)
                            Spacer()
                            if dish.id == session.selectedDishID {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                            }
                        }
                    }
                    .disabled(dish.id == session.selectedDishID || store.isCookingCommandPending())
                    .accessibilityLabel(dish.name)
                    .accessibilityValue(
                        dish.id == session.selectedDishID
                            ? String(localized: "Current dish")
                            : String(localized: "Not selected")
                    )
                }
            }
        }

        if let dish = selectedDish {
            Section {
                if dish.ingredients.isEmpty {
                    Text(String(localized: "No ingredients added."))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(dish.ingredients) { ingredient in
                        Button {
                            store.sendCookingCommand(
                                action: .toggleIngredient(
                                    dishID: dish.id,
                                    ingredientIndex: ingredient.index
                                )
                            )
                        } label: {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: ingredient.isChecked ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(ingredient.isChecked ? .green : .secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(ingredient.name)
                                        .strikethrough(ingredient.isChecked)
                                    if let amount = ingredient.amount {
                                        Text(amount)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    if let note = ingredient.note {
                                        Text(note)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                        }
                        .disabled(store.isCookingCommandPending(for: dish.id))
                        .accessibilityLabel(ingredient.name)
                        .accessibilityValue(
                            ingredient.isChecked
                                ? String(localized: "Checked off")
                                : String(localized: "Not checked off")
                        )
                    }
                }
            } header: {
                Text(String(localized: "Ingredients"))
            }
        }

        Section {
            if session.timers.isEmpty {
                Text(String(localized: "No active cooking timers."))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(session.timers) { timer in
                    WatchCookingTimerRow(timer: timer, now: now)
                }
            }
        } header: {
            Text(String(localized: "Timers"))
        }

        if let feedback = store.cookingCommandFeedback {
            WatchCookingCommandFeedbackView(feedback: feedback)
        }

        if !store.isReachable {
            Label(
                String(localized: "Showing the last handoff. Changes will sync when iPhone is reachable."),
                systemImage: "iphone.slash"
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
        }
        WatchSyncFooter()
    }
}

private struct WatchCookingTimerRow: View {

    @Environment(WatchDataStore.self) private var store
    let timer: WatchCookingTimer
    let now: Date

    @State private var confirmingCancellation = false

    private var state: WatchCookingTimer.State { timer.state(at: now) }
    private var pending: Bool { store.isTimerCommandPending(for: timer.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 8) {
                NavigationLink {
                    WatchCookingTimerDetailView(timer: timer)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(timer.label)
                            .font(.headline)
                            .lineLimit(2)
                        Text(timer.contextLabel)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)

                VStack(alignment: .trailing, spacing: 2) {
                    Text(Self.duration(timer.remaining(at: now)))
                        .font(.system(.title3, design: .monospaced).weight(.semibold))
                        .monospacedDigit()
                        .minimumScaleFactor(0.7)
                    Text(stateTitle)
                        .font(.caption2)
                        .foregroundStyle(state == .completed ? .orange : .secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(
                    "\(timer.label), \(timer.contextLabel), \(Self.duration(timer.remaining(at: now)))"
                )
                .accessibilityValue(stateTitle)
            }

            HStack(spacing: 8) {
                if state == .completed {
                    Button {
                        confirmingCancellation = true
                    } label: {
                        Label(String(localized: "Dismiss"), systemImage: "checkmark")
                    }
                    .tint(.orange)
                } else {
                    Button {
                        store.sendTimerCommand(
                            for: timer,
                            action: .pauseOrResume
                        )
                    } label: {
                        Label(
                            state == .paused
                                ? String(localized: "Resume")
                                : String(localized: "Pause"),
                            systemImage: state == .paused ? "play.fill" : "pause.fill"
                        )
                    }
                    .disabled(pending)
                }

                if state == .completed {
                    Button {
                        store.sendTimerCommand(for: timer, action: .repeatTimer)
                    } label: {
                        Label(String(localized: "Repeat"), systemImage: "arrow.clockwise")
                    }
                    .disabled(pending)
                } else {
                    Button {
                        store.sendTimerCommand(for: timer, action: .extend)
                    } label: {
                        Label(String(localized: "+1 minute"), systemImage: "plus")
                    }
                    .disabled(pending)
                }

                Button(role: .destructive) {
                    confirmingCancellation = true
                } label: {
                    Label(String(localized: "Cancel"), systemImage: "xmark")
                }
                .disabled(pending)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .confirmationDialog(
                String(localized: "Cancel this cooking timer?"),
                isPresented: $confirmingCancellation,
                titleVisibility: .visible
            ) {
                Button(String(localized: "Cancel Timer"), role: .destructive) {
                    store.sendTimerCommand(for: timer, action: .cancel)
                }
                Button(String(localized: "Keep Timer"), role: .cancel) {}
            }

            if pending {
                Label(
                    String(localized: "Waiting for iPhone…"),
                    systemImage: "arrow.triangle.2.circlepath"
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }

    private var stateTitle: String {
        switch state {
        case .running: String(localized: "Running")
        case .paused: String(localized: "Paused")
        case .completed: String(localized: "Completed")
        }
    }

    fileprivate static func duration(_ value: TimeInterval) -> String {
        let seconds = max(0, Int(value.rounded(.up)))
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        let remainder = seconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainder)
        }
        return String(format: "%d:%02d", minutes, remainder)
    }
}

private struct WatchCookingTimerDetailView: View {

    let timer: WatchCookingTimer

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text(timer.label)
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(timer.contextLabel)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(WatchCookingTimerRow.duration(timer.remaining(at: timeline.date)))
                        .font(.system(size: 36, weight: .semibold, design: .monospaced))
                        .monospacedDigit()
                        .minimumScaleFactor(0.6)
                        .accessibilityLabel(String(localized: "Time remaining"))
                    if !timer.stepText.isEmpty {
                        Divider()
                        Text(timer.stepText)
                            .font(.footnote)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .navigationTitle(String(localized: "Timer"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct WatchTimerFeedbackView: View {

    let feedback: WatchTimerCommandFeedback

    var body: some View {
        Label {
            Text(feedback.message ?? (
                feedback.accepted
                    ? String(localized: "Updated on iPhone.")
                    : String(localized: "iPhone could not update this timer.")
            ))
        } icon: {
            Image(systemName: feedback.accepted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(feedback.accepted ? .green : .orange)
        }
        .font(.caption)
        .listRowBackground(Color.clear)
        .accessibilityElement(children: .combine)
    }
}

private struct WatchCookingCommandFeedbackView: View {

    let feedback: WatchCookingCommandFeedback

    var body: some View {
        Label {
            Text(feedback.message ?? (
                feedback.accepted
                    ? String(localized: "Updated on iPhone.")
                    : String(localized: "iPhone could not update the cooking session.")
            ))
        } icon: {
            Image(systemName: feedback.accepted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(feedback.accepted ? .green : .orange)
        }
        .font(.caption)
        .listRowBackground(Color.clear)
        .accessibilityElement(children: .combine)
    }
}
