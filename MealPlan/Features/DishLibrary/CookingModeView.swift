import SwiftUI
import SwiftData
import UserNotifications
#if canImport(UIKit)
import UIKit
#endif

private struct ActiveCookingTimer: Identifiable, Equatable, Sendable {
    let id = UUID()
    var name: String
    var duration: TimeInterval
    var endDate: Date
    var pausedRemaining: TimeInterval?

    func remaining(at date: Date) -> TimeInterval {
        max(0, pausedRemaining ?? endDate.timeIntervalSince(date))
    }
}

/// A distraction-free, stateful view of a recipe for use at the stove.
/// Progress intentionally stays local to the session; reopening a recipe
/// starts with a clean mise en place.
@MainActor
struct CookingModeView: View {
    let dish: Dish

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var targetServings: Int
    @State private var checkedIngredients: Set<Int> = []
    @State private var currentStep = 0
    @State private var timers: [ActiveCookingTimer] = []
    #if os(macOS)
    @State private var sleepActivity: NSObjectProtocol?
    #endif

    init(dish: Dish) {
        self.dish = dish
        _targetServings = State(initialValue: max(1, dish.servings))
    }

    private var steps: [CookingStep] { CookingRecipe.steps(from: dish.recipeText) }
    private var scaler: ServingScaler {
        ServingScaler(
            baseServings: dish.servings,
            targetServings: targetServings,
            system: appState.unitSystem,
            roundsAmounts: appState.roundsDisplayedAmounts
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                servingsControl
                ingredients
                directions
                if !timers.isEmpty { activeTimers }
            }
            .padding()
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(dish.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(String(localized: "Done")) { dismiss() }
            }
        }
        .onAppear(perform: keepScreenAwake)
        .onDisappear(perform: releaseScreen)
    }

    private var servingsControl: some View {
        HStack {
            Label(String(localized: "Cooking mode"), systemImage: "frying.pan")
                .font(.title2.bold())
            Spacer()
            Stepper(value: $targetServings, in: 1...50) {
                Text(String(localized: "\(targetServings) servings"))
                    .monospacedDigit()
            }
            .fixedSize()
        }
    }

    private var ingredients: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(String(localized: "Ingredients")).font(.title2.bold())
            if dish.sortedIngredients.isEmpty {
                Text(String(localized: "No ingredients added yet."))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(dish.sortedIngredients.enumerated()), id: \.element.id) { index, line in
                    Button {
                        if checkedIngredients.contains(index) { checkedIngredients.remove(index) }
                        else { checkedIngredients.insert(index) }
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Image(systemName: checkedIngredients.contains(index) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(checkedIngredients.contains(index) ? .green : .secondary)
                            Text(line.ingredient?.name ?? line.rawText ?? "—")
                                .strikethrough(checkedIngredients.contains(index))
                            Spacer()
                            if let amount = scaler.amountText(for: line) {
                                Text(amount).foregroundStyle(.secondary).monospacedDigit()
                            }
                        }
                        .font(.title3)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Divider()
                }
            }
        }
    }

    @ViewBuilder
    private var directions: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(String(localized: "Method")).font(.title2.bold())
            if steps.isEmpty {
                Text(String(localized: "No cooking steps added yet."))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(steps) { step in
                    Button { currentStep = step.id } label: {
                        HStack(alignment: .top, spacing: 14) {
                            Text("\(step.id + 1)")
                                .font(.headline.monospacedDigit())
                                .frame(width: 34, height: 34)
                                .background(step.id == currentStep ? Color.accentColor : Color.secondary.opacity(0.14), in: Circle())
                                .foregroundStyle(step.id == currentStep ? .white : .secondary)
                            VStack(alignment: .leading, spacing: 10) {
                                Text(step.text)
                                    .font(step.id == currentStep ? .title3.weight(.semibold) : .title3)
                                    .foregroundStyle(step.id <= currentStep ? .primary : .secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                if step.id == currentStep, !step.timers.isEmpty {
                                    HStack {
                                        ForEach(step.timers) { suggestion in
                                            Button {
                                                startTimer(suggestion, step: step.id + 1)
                                            } label: {
                                                Label(suggestion.label, systemImage: "timer")
                                            }
                                            .buttonStyle(.borderedProminent)
                                        }
                                    }
                                }
                            }
                        }
                        .padding(14)
                        .background(step.id == currentStep ? Color.accentColor.opacity(0.10) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 16))
                    }
                    .buttonStyle(.plain)
                }

                HStack {
                    Button(String(localized: "Previous"), systemImage: "chevron.left") {
                        currentStep = max(0, currentStep - 1)
                    }
                    .disabled(currentStep == 0)
                    Spacer()
                    Button(String(localized: "Next"), systemImage: "chevron.right") {
                        currentStep = min(steps.count - 1, currentStep + 1)
                    }
                    .labelStyle(.titleAndIcon)
                    .disabled(currentStep >= steps.count - 1)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var activeTimers: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(String(localized: "Timers")).font(.title2.bold())
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                VStack(spacing: 10) {
                    ForEach(timers) { timer in
                        let remaining = timer.remaining(at: timeline.date)
                        HStack {
                            Image(systemName: remaining <= 0 ? "alarm.waves.left.and.right.fill" : "timer")
                                .foregroundStyle(remaining <= 0 ? .red : .accentColor)
                            VStack(alignment: .leading) {
                                Text(timer.name).font(.headline)
                                Text(clockText(remaining)).font(.title2.monospacedDigit())
                            }
                            Spacer()
                            Button(timer.pausedRemaining == nil ? String(localized: "Pause") : String(localized: "Resume")) {
                                toggle(timer.id, at: timeline.date)
                            }
                            Button(String(localized: "Cancel"), role: .destructive) {
                                cancelTimer(timer.id)
                            }
                        }
                        .padding(12)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                    }
                }
            }
        }
    }

    private func startTimer(_ suggestion: RecipeTimerSuggestion, step: Int) {
        let timer = ActiveCookingTimer(
            name: String(localized: "Step \(step): \(suggestion.label)"),
            duration: suggestion.duration,
            endDate: .now.addingTimeInterval(suggestion.duration)
        )
        timers.append(timer)
        Task { await CookingTimerNotifier.schedule(timer) }
    }

    private func toggle(_ id: UUID, at date: Date) {
        guard let index = timers.firstIndex(where: { $0.id == id }) else { return }
        if let remaining = timers[index].pausedRemaining {
            timers[index].pausedRemaining = nil
            timers[index].endDate = date.addingTimeInterval(remaining)
            let timer = timers[index]
            Task { await CookingTimerNotifier.schedule(timer, after: remaining) }
        } else {
            timers[index].pausedRemaining = timers[index].remaining(at: date)
            CookingTimerNotifier.cancel(id)
        }
    }

    private func cancelTimer(_ id: UUID) {
        timers.removeAll { $0.id == id }
        CookingTimerNotifier.cancel(id)
    }

    private func clockText(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval.rounded(.up)))
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let remainder = seconds % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, remainder)
            : String(format: "%02d:%02d", minutes, remainder)
    }

    private func keepScreenAwake() {
        #if canImport(UIKit)
        UIApplication.shared.isIdleTimerDisabled = true
        #elseif os(macOS)
        sleepActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "Cooking with MealPlan"
        )
        #endif
    }

    private func releaseScreen() {
        #if canImport(UIKit)
        UIApplication.shared.isIdleTimerDisabled = false
        #elseif os(macOS)
        if let sleepActivity { ProcessInfo.processInfo.endActivity(sleepActivity) }
        sleepActivity = nil
        #endif
    }
}

private enum CookingTimerNotifier {
    static func schedule(_ timer: ActiveCookingTimer, after interval: TimeInterval? = nil) async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
        }
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Cooking timer finished")
        content.body = timer.name
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: max(1, interval ?? timer.duration), repeats: false
        )
        try? await center.add(UNNotificationRequest(
            identifier: identifier(timer.id), content: content, trigger: trigger
        ))
    }

    static func cancel(_ id: UUID) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [identifier(id)])
    }

    private static func identifier(_ id: UUID) -> String { "cooking-timer-\(id.uuidString)" }
}

#Preview {
    NavigationStack { CookingModeView(dish: PreviewData.household.dishes?.first ?? Dish(name: "Test")) }
        .environment(AppState.preview)
        .modelContainer(PreviewData.container)
}
