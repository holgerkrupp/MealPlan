import SwiftData
import SwiftUI

/// A distraction-free menu cooking view. The durable state lives on
/// `AppState`, so closing this sheet is an interruption rather than a reset.
@MainActor
struct CookingModeView: View {
    let dish: Dish

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Dish.name) private var allDishes: [Dish]

    @AppStorage("CookingMode.textScale") private var textScale = 1.0
    @State private var didEnter = false
    @State private var holdsDisplayAwake = false
    @State private var showingResumePrompt = false
    @State private var showingDishPicker = false
    @State private var showingManualTimer = false

    private var store: CookingSessionStore { appState.cookingSession }

    private var currentDish: Dish {
        guard let id = store.session?.selectedDishID else { return dish }
        return allDishes.first(where: { $0.uuid == id }) ?? dish
    }

    private var progress: CookingDishProgress {
        store.session?.dishes.first(where: { $0.id == currentDish.uuid })
            ?? CookingDishProgress(id: currentDish.uuid, name: currentDish.name, targetServings: appState.standardServings)
    }

    private var steps: [CookingStep] { CookingRecipe.steps(from: currentDish.recipeText) }

    private var scaler: ServingScaler {
        ServingScaler(
            baseServings: currentDish.servings,
            targetServings: progress.targetServings,
            system: appState.unitSystem,
            roundsAmounts: appState.roundsDisplayedAmounts
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                sessionDishStrip
                servingsControl
                ingredients
                directions
                if !(store.session?.timers.isEmpty ?? true) { activeTimers }
            }
            .padding()
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(currentDish.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar { cookingToolbar }
        .onAppear(perform: enterCookingMode)
        .onDisappear(perform: releaseDisplayAwake)
        .alert(String(localized: "Resume cooking session?"), isPresented: $showingResumePrompt) {
            Button(String(localized: "Resume")) {
                if store.session?.dishes.contains(where: { $0.id == dish.uuid }) == true {
                    store.select(dish.uuid)
                }
            }
            Button(String(localized: "Start new"), role: .destructive) {
                store.finish()
                store.begin(with: dish, servings: appState.standardServings)
            }
        } message: {
            Text(String(localized: "Your dishes, steps, ingredients and timers are still here."))
        }
        .sheet(isPresented: $showingDishPicker) {
            CookingDishPicker(
                dishes: availableDishes,
                suggestions: plannedCompanions,
                onAdd: { store.add($0, servings: appState.standardServings) }
            )
        }
        .sheet(isPresented: $showingManualTimer) {
            ManualCookingTimerSheet(
                dishName: currentDish.name,
                stepNumber: progress.currentStep + 1,
                onStart: startManualTimer
            )
        }
    }

    @ToolbarContentBuilder
    private var cookingToolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button(String(localized: "Close")) { dismiss() }
        }
        ToolbarItem {
            Menu {
                Button(String(localized: "Smaller text"), systemImage: "textformat.size.smaller") {
                    textScale = max(0.85, textScale - 0.1)
                }
                .disabled(textScale <= 0.85)
                Button(String(localized: "Larger text"), systemImage: "textformat.size.larger") {
                    textScale = min(1.6, textScale + 0.1)
                }
                .disabled(textScale >= 1.6)
                Button(String(localized: "Default text size")) { textScale = 1 }
            } label: {
                Label(String(localized: "Text size"), systemImage: "textformat.size")
            }
        }
        ToolbarItem(placement: .confirmationAction) {
            Button(String(localized: "Finish session")) {
                store.finish()
                dismiss()
            }
        }
    }

    private var sessionDishStrip: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(String(localized: "Cooking session"), systemImage: "frying.pan")
                    .font(.title2.bold())
                Spacer()
                Button(String(localized: "Add dish"), systemImage: "plus") {
                    showingDishPicker = true
                }
                .buttonStyle(.bordered)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(store.session?.dishes ?? []) { item in
                        if item.id == currentDish.uuid {
                            Button(item.name) { store.select(item.id) }
                                .buttonStyle(.borderedProminent)
                        } else {
                            Button(item.name) { store.select(item.id) }
                                .buttonStyle(.bordered)
                        }
                    }
                }
            }
        }
    }

    private var servingsControl: some View {
        HStack {
            Text(String(localized: "Servings")).font(.headline)
            Spacer()
            Stepper(value: servingsBinding, in: 1...50) {
                Text(String(localized: "\(progress.targetServings) servings"))
                    .monospacedDigit()
            }
            .fixedSize()
        }
    }

    private var servingsBinding: Binding<Int> {
        Binding(
            get: { progress.targetServings },
            set: { store.setServings($0, for: currentDish.uuid) }
        )
    }

    private var ingredients: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(String(localized: "Ingredients")).font(.title2.bold())
            if currentDish.sortedIngredients.isEmpty {
                Text(String(localized: "No ingredients added yet."))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(currentDish.sortedIngredients.enumerated()), id: \.offset) { index, line in
                    let checked = progress.checkedIngredientIndexes.contains(index)
                    Button { store.toggleIngredient(index, for: currentDish.uuid) } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(checked ? .green : .secondary)
                            Text(line.ingredient?.name ?? line.rawText ?? "—")
                                .strikethrough(checked)
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
            HStack {
                Text(String(localized: "Method")).font(.title2.bold())
                Spacer()
                Button(String(localized: "Add timer"), systemImage: "timer") {
                    showingManualTimer = true
                }
                .buttonStyle(.bordered)
            }
            if steps.isEmpty {
                Text(String(localized: "No cooking steps added yet."))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(steps) { step in
                    let isCurrent = step.id == progress.currentStep
                    HStack(alignment: .top, spacing: 14) {
                        Text("\(step.id + 1)")
                            .font(.headline.monospacedDigit())
                            .frame(width: 38, height: 38)
                            .background(isCurrent ? Color.accentColor : Color.secondary.opacity(0.14), in: Circle())
                            .foregroundStyle(isCurrent ? .white : .secondary)
                        VStack(alignment: .leading, spacing: 12) {
                            Text(step.text)
                                .font(.system(size: (isCurrent ? 25 : 20) * textScale, weight: isCurrent ? .semibold : .regular))
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if isCurrent, !step.timers.isEmpty {
                                FlowLayout(spacing: 8) {
                                    ForEach(step.timers) { suggestion in
                                        Button {
                                            startTimer(suggestion, step: step)
                                        } label: {
                                            Label(suggestion.label, systemImage: "timer")
                                        }
                                        .buttonStyle(.borderedProminent)
                                    }
                                }
                            }
                        }
                    }
                    .opacity(isCurrent ? 1 : (abs(step.id - progress.currentStep) == 1 ? 0.58 : 0.34))
                    .padding(16)
                    .background(isCurrent ? Color.accentColor.opacity(0.10) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 16))
                    .contentShape(Rectangle())
                    .onTapGesture {
                        store.setCurrentStep(step.id, for: currentDish.uuid, stepCount: steps.count)
                    }
                }

                HStack {
                    Button(String(localized: "Previous"), systemImage: "chevron.left") {
                        store.setCurrentStep(progress.currentStep - 1, for: currentDish.uuid, stepCount: steps.count)
                    }
                    .disabled(progress.currentStep == 0)
                    Spacer()
                    Button(String(localized: "Next"), systemImage: "chevron.right") {
                        store.setCurrentStep(progress.currentStep + 1, for: currentDish.uuid, stepCount: steps.count)
                    }
                    .disabled(progress.currentStep >= steps.count - 1)
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
                    ForEach(store.session?.timers ?? []) { timer in
                        let remaining = timer.remaining(at: timeline.date)
                        HStack {
                            Image(systemName: remaining <= 0 ? "alarm.waves.left.and.right.fill" : "timer")
                                .foregroundStyle(remaining <= 0 ? .red : .accentColor)
                            VStack(alignment: .leading) {
                                Text(timer.contextLabel).font(.caption).foregroundStyle(.secondary)
                                Text(timer.label).font(.headline)
                                Text(clockText(remaining)).font(.title2.monospacedDigit())
                            }
                            Spacer()
                            Button(timer.pausedRemaining == nil ? String(localized: "Pause") : String(localized: "Resume")) {
                                store.pauseOrResumeTimer(timer.id, at: timeline.date)
                            }
                            Button(String(localized: "Cancel"), role: .destructive) {
                                store.cancelTimer(timer.id)
                            }
                        }
                        .padding(12)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                    }
                }
            }
        }
    }

    private var availableDishes: [Dish] {
        let existing = Set(store.session?.dishes.map(\.id) ?? [])
        return allDishes.filter { candidate in
            !existing.contains(candidate.uuid)
                && (candidate.household?.uuid == appState.currentHousehold?.uuid)
        }
    }

    /// A dish planned beside the starting/current dish on the selected day is
    /// the most likely second thing the cook wants at the stove.
    private var plannedCompanions: [Dish] {
        let day = appState.selectedDate.startOfDay
        let mealKeys = Set((currentDish.entries ?? [])
            .filter { $0.date.startOfDay == day }
            .map(\.mealKey))
        guard !mealKeys.isEmpty else { return [] }
        return availableDishes.filter { candidate in
            (candidate.entries ?? []).contains {
                $0.date.startOfDay == day && mealKeys.contains($0.mealKey)
            }
        }
    }

    private func enterCookingMode() {
        guard !didEnter else { return }
        didEnter = true
        DisplayAwakeCoordinator.shared.acquire()
        holdsDisplayAwake = true
        if store.hasInterruptedSession {
            showingResumePrompt = true
        } else {
            store.begin(with: dish, servings: appState.standardServings)
        }
    }

    private func releaseDisplayAwake() {
        guard holdsDisplayAwake else { return }
        holdsDisplayAwake = false
        DisplayAwakeCoordinator.shared.release()
    }

    private func startTimer(_ suggestion: RecipeTimerSuggestion, step: CookingStep) {
        store.startTimer(
            dishID: currentDish.uuid,
            dishName: currentDish.name,
            stepNumber: step.id + 1,
            stepText: step.text,
            label: suggestion.label,
            duration: suggestion.duration
        )
    }

    private func startManualTimer(label: String, duration: TimeInterval) {
        let step = steps.indices.contains(progress.currentStep) ? steps[progress.currentStep] : nil
        store.startTimer(
            dishID: currentDish.uuid,
            dishName: currentDish.name,
            stepNumber: progress.currentStep + 1,
            stepText: step?.text ?? String(localized: "Manual timer"),
            label: label,
            duration: duration
        )
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
}

@MainActor
private struct CookingDishPicker: View {
    let dishes: [Dish]
    let suggestions: [Dish]
    let onAdd: (Dish) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    var body: some View {
        NavigationStack {
            List {
                if !suggestions.isEmpty {
                    Section(String(localized: "Planned for this meal")) {
                        ForEach(suggestions) { dish in addButton(for: dish) }
                    }
                }
                Section(String(localized: "Dish library")) {
                    ForEach(filteredDishes) { dish in addButton(for: dish) }
                }
            }
            .navigationTitle(String(localized: "Add a dish"))
            .searchable(text: $searchText, prompt: String(localized: "Search dishes"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Done")) { dismiss() }
                }
            }
        }
    }

    private var filteredDishes: [Dish] {
        let suggestions = Set(suggestions.map(\.uuid))
        let remaining = dishes.filter { !suggestions.contains($0.uuid) }
        guard !searchText.isEmpty else { return remaining }
        return remaining.filter { $0.searchableText.localizedCaseInsensitiveContains(searchText) }
    }

    private func addButton(for dish: Dish) -> some View {
        Button {
            onAdd(dish)
            dismiss()
        } label: {
            Label(dish.name, systemImage: dish.glyph?.symbolName ?? "fork.knife")
        }
    }
}

@MainActor
private struct ManualCookingTimerSheet: View {
    let dishName: String
    let stepNumber: Int
    let onStart: (String, TimeInterval) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var label = ""
    @State private var minutes = 5

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(String(localized: "Timer label"), text: $label)
                    Stepper(value: $minutes, in: 1...360) {
                        Text(String(localized: "\(minutes) minutes"))
                    }
                } header: {
                    Text("\(dishName) · \(String(localized: "Step \(stepNumber)"))")
                }
            }
            .navigationTitle(String(localized: "Manual timer"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Start timer")) {
                        let clean = label.trimmingCharacters(in: .whitespacesAndNewlines)
                        onStart(clean.isEmpty ? String(localized: "Timer") : clean, TimeInterval(minutes * 60))
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

#Preview {
    NavigationStack { CookingModeView(dish: PreviewData.household.dishes?.first ?? Dish(name: "Test")) }
        .environment(AppState.preview)
        .modelContainer(PreviewData.container)
}
