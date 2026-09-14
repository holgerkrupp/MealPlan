#if os(visionOS)
import SwiftData
import SwiftUI

/// The independently placeable parts of a spatial cooking session.
///
/// These values intentionally do not carry a dish identifier. A cooking
/// session can contain several dishes, and changing the selected dish should
/// update every open panel instead of creating another set of windows.
enum SpatialCookingWindowRoute: String, Codable, Hashable, Identifiable, CaseIterable {
    case ingredients
    case instructions
    case timers

    var id: String { rawValue }
}

/// The compact control window opened by the recipe's Cook button. It starts or
/// resumes the durable cooking session and places ingredients and instructions
/// in their own windows. The cook remains free to move, resize, or close each
/// panel using the standard visionOS window controls.
@MainActor
struct SpatialCookingGuideView: View {
    let dish: Dish

    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.scenePhase) private var scenePhase
    @Query(sort: \Dish.name) private var allDishes: [Dish]

    @AppStorage("CookingMode.speakSteps") private var speakSteps = true
    @AppStorage("CookingMode.voiceControl") private var voiceControlEnabled = false
    @State private var didPrepare = false
    @State private var showingResumePrompt = false
    @State private var microphonePermissionDenied = false
    @State private var narrator = CookingNarrator()
    @State private var voice = CookingVoiceController()

    private var store: CookingSessionStore { appState.cookingSession }

    private var currentDish: Dish {
        guard let selectedID = store.session?.selectedDishID else { return dish }
        return allDishes.first(where: { $0.uuid == selectedID }) ?? dish
    }

    private var progress: CookingDishProgress {
        store.session?.dishes.first(where: { $0.id == currentDish.uuid })
            ?? CookingDishProgress(
                id: currentDish.uuid,
                name: currentDish.name,
                targetServings: appState.standardServings
            )
    }

    private var steps: [CookingStep] {
        CookingRecipe.steps(from: currentDish.displayRecipeText(translated: currentDish.prefersTranslation))
    }

    private var currentStep: CookingStep? {
        steps.indices.contains(progress.currentStep) ? steps[progress.currentStep] : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            sessionHeader
            currentStepCard
            stepControls
            panelButtons
            timerSummary
            Spacer(minLength: 0)
            sessionActions
        }
        .padding(28)
        .frame(minWidth: 520, minHeight: 500)
        .glassBackgroundEffect()
        .onAppear {
            prepareSession()
            voice.onCommand = { command in handle(command) }
            if voiceControlEnabled {
                Task { await startVoiceControl(requesting: false) }
            }
        }
        .onChange(of: progress.currentStep) { _, _ in
            speakCurrentStep(force: false)
        }
        .onChange(of: currentDish.uuid) { _, _ in
            speakCurrentStep(force: false)
        }
        .onChange(of: voiceControlEnabled) { _, enabled in
            if enabled {
                Task { await startVoiceControl(requesting: true) }
            } else {
                voice.stop()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                narrator.stop()
                voice.stop()
            } else if voiceControlEnabled, !voice.isListening {
                Task { await startVoiceControl(requesting: false) }
            }
        }
        .onDisappear {
            narrator.stop()
            voice.stop()
        }
        .alert(String(localized: "Resume cooking session?"), isPresented: $showingResumePrompt) {
            Button(String(localized: "Resume")) {
                openCorePanels()
                speakCurrentStep(force: false)
            }
            Button(String(localized: "Start new"), role: .destructive) {
                store.finish()
                store.begin(with: dish, servings: appState.standardServings)
                openCorePanels()
                speakCurrentStep(force: false)
            }
        } message: {
            Text(String(localized: "Your dishes, steps, ingredients and timers are still here."))
        }
        .alert(String(localized: "Microphone access is off"), isPresented: $microphonePermissionDenied) {
            Button(String(localized: "OK"), role: .cancel) {}
        } message: {
            Text(String(localized: "To use hands-free voice control, allow microphone and speech recognition for MealPlan in Settings."))
        }
    }

    private var sessionHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(String(localized: "Spatial cooking guide"), systemImage: "frying.pan.fill")
                .font(.title2.bold())
                .foregroundStyle(.secondary)

            Text(currentDish.displayName(translated: currentDish.prefersTranslation))
                .font(.largeTitle.bold())
                .lineLimit(2)

            if (store.session?.dishes.count ?? 0) > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
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
    }

    @ViewBuilder
    private var currentStepCard: some View {
        if let currentStep {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(String(localized: "Step \(currentStep.id + 1) of \(steps.count)"))
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if !currentStep.timers.isEmpty {
                        Label(String(localized: "Timer available"), systemImage: "timer")
                            .font(.caption)
                            .foregroundStyle(.tint)
                    }
                }
                Text(currentStep.text)
                    .font(.title2.weight(.semibold))
                    .lineLimit(5)
                    .minimumScaleFactor(0.75)
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 22))
        } else {
            ContentUnavailableView(
                String(localized: "No cooking steps"),
                systemImage: "list.number",
                description: Text(String(localized: "Add instructions to this recipe to step through them here."))
            )
            .frame(maxWidth: .infinity)
        }
    }

    private var stepControls: some View {
        HStack(spacing: 12) {
            Button {
                moveStep(by: -1)
            } label: {
                Label(String(localized: "Previous"), systemImage: "chevron.left")
                    .frame(maxWidth: .infinity)
            }
            .disabled(progress.currentStep == 0 || steps.isEmpty)

            Button {
                speakCurrentStep(force: true)
            } label: {
                Label(String(localized: "Repeat"), systemImage: "speaker.wave.2")
            }
            .disabled(currentStep == nil)

            Button {
                moveStep(by: 1)
            } label: {
                Label(String(localized: "Next"), systemImage: "chevron.right")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(steps.isEmpty || progress.currentStep >= steps.count - 1)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
    }

    private var panelButtons: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(localized: "Cooking windows"))
                .font(.headline)
            HStack(spacing: 12) {
                panelButton(
                    String(localized: "Ingredients"),
                    symbol: "carrot",
                    route: .ingredients
                )
                panelButton(
                    String(localized: "Instructions"),
                    symbol: "list.number",
                    route: .instructions
                )
                panelButton(
                    String(localized: "Timers"),
                    symbol: "timer",
                    route: .timers
                )
            }
        }
    }

    private func panelButton(_ title: String, symbol: String, route: SpatialCookingWindowRoute) -> some View {
        Button {
            openWindow(value: route)
        } label: {
            VStack(spacing: 8) {
                Image(systemName: symbol).font(.title2)
                Text(title).font(.caption)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
    }

    @ViewBuilder
    private var timerSummary: some View {
        if let timers = store.session?.timers, !timers.isEmpty {
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                Button {
                    openWindow(value: SpatialCookingWindowRoute.timers)
                } label: {
                    HStack {
                        Image(systemName: "timer")
                        Text(timers.count == 1
                            ? String(localized: "1 active timer")
                            : String(localized: "\(timers.count) active timers"))
                        Spacer()
                        Text(Self.clockText(timers.map { $0.remaining(at: timeline.date) }.min() ?? 0))
                            .font(.headline.monospacedDigit())
                    }
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var sessionActions: some View {
        HStack {
            Toggle(String(localized: "Read steps aloud"), isOn: $speakSteps)
                .toggleStyle(.button)
            if voice.isAvailable {
                Toggle(isOn: $voiceControlEnabled) {
                    Label(
                        String(localized: "Voice control"),
                        systemImage: voice.isListening ? "waveform.circle.fill" : "mic"
                    )
                }
                .toggleStyle(.button)
            }
            Spacer()
            Button(String(localized: "Finish session"), role: .destructive) {
                finishSession()
            }
        }
    }

    private func prepareSession() {
        guard !didPrepare else { return }
        didPrepare = true
        if store.hasInterruptedSession {
            if store.session?.dishes.contains(where: { $0.id == dish.uuid }) == true {
                store.select(dish.uuid)
                openCorePanels()
                speakCurrentStep(force: false)
            } else {
                showingResumePrompt = true
            }
        } else {
            store.begin(with: dish, servings: appState.standardServings)
            openCorePanels()
            speakCurrentStep(force: false)
        }
    }

    private func openCorePanels() {
        openWindow(value: SpatialCookingWindowRoute.ingredients)
        openWindow(value: SpatialCookingWindowRoute.instructions)
    }

    private func moveStep(by offset: Int) {
        store.setCurrentStep(
            progress.currentStep + offset,
            for: currentDish.uuid,
            stepCount: steps.count
        )
    }

    private func speakCurrentStep(force: Bool) {
        guard force || speakSteps, let currentStep else { return }
        narrator.languageCode = currentDish.prefersTranslation
            ? currentDish.translationLanguageCode
            : currentDish.recipeLanguageCode
        narrator.audioSessionManagedExternally = voice.isListening
        narrator.speak("\(String(localized: "Step \(currentStep.id + 1)")). \(currentStep.text)")
    }

    private func startVoiceControl(requesting: Bool) async {
        if requesting {
            guard await voice.requestAuthorization() else {
                voiceControlEnabled = false
                microphonePermissionDenied = true
                return
            }
        }
        narrator.audioSessionManagedExternally = true
        voice.start()
        if !voice.isListening { voiceControlEnabled = false }
    }

    private func handle(_ command: CookingVoiceController.Command) {
        switch command {
        case .next, .markStepDone:
            moveStep(by: 1)
        case .back:
            moveStep(by: -1)
        case .repeatStep:
            speakCurrentStep(force: true)
        case .startTimer:
            guard let currentStep, let suggestion = currentStep.timers.first else {
                openWindow(value: SpatialCookingWindowRoute.timers)
                return
            }
            startTimer(suggestion, step: currentStep)
            openWindow(value: SpatialCookingWindowRoute.timers)
        case .stop:
            voiceControlEnabled = false
        }
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

    private func finishSession() {
        narrator.stop()
        voice.stop()
        store.finish()
        for route in SpatialCookingWindowRoute.allCases {
            dismissWindow(value: route)
        }
        dismissWindow(value: DetailWindowRoute.cookRecipe(dish.uuid))
    }

    fileprivate static func clockText(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval.rounded(.up)))
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let remainder = seconds % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, remainder)
            : String(format: "%02d:%02d", minutes, remainder)
    }
}

/// Resolves the recipe selected by the shared session and hosts the requested
/// cooking panel. Keeping the query at this level makes all open windows switch
/// dishes together.
@MainActor
struct SpatialCookingWindow: View {
    let route: SpatialCookingWindowRoute

    @Environment(AppState.self) private var appState
    @Query(sort: \Dish.name) private var dishes: [Dish]

    private var dish: Dish? {
        guard let id = appState.cookingSession.session?.selectedDishID else { return nil }
        return dishes.first(where: { $0.uuid == id })
    }

    var body: some View {
        NavigationStack {
            if let dish {
                switch route {
                case .ingredients:
                    SpatialIngredientsView(dish: dish)
                case .instructions:
                    SpatialInstructionsView(dish: dish)
                case .timers:
                    SpatialTimersView()
                }
            } else {
                ContentUnavailableView(
                    String(localized: "No active cooking session"),
                    systemImage: "frying.pan",
                    description: Text(String(localized: "Choose Cook from a recipe to start."))
                )
            }
        }
        .glassBackgroundEffect()
    }
}

@MainActor
private struct SpatialIngredientsView: View {
    let dish: Dish

    @Environment(AppState.self) private var appState
    @AppStorage("CookingMode.textScale") private var textScale = 1.0

    private var store: CookingSessionStore { appState.cookingSession }

    private var progress: CookingDishProgress {
        store.session?.dishes.first(where: { $0.id == dish.uuid })
            ?? CookingDishProgress(id: dish.uuid, name: dish.name, targetServings: appState.standardServings)
    }

    private var scaler: ServingScaler {
        ServingScaler(
            baseServings: dish.servings,
            targetServings: progress.targetServings,
            system: appState.unitSystem,
            roundsAmounts: appState.roundsDisplayedAmounts
        )
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                servingsControl
                    .padding(.bottom, 18)

                if dish.sortedIngredients.isEmpty {
                    ContentUnavailableView(
                        String(localized: "No ingredients"),
                        systemImage: "carrot",
                        description: Text(String(localized: "No ingredients have been added to this recipe yet."))
                    )
                } else {
                    ForEach(Array(dish.sortedIngredients.enumerated()), id: \.offset) { index, ingredient in
                        ingredientButton(ingredient, at: index)
                        if index < dish.sortedIngredients.count - 1 { Divider() }
                    }
                }
            }
            .padding(24)
        }
        .navigationTitle(String(localized: "Ingredients · \(dish.displayName(translated: dish.prefersTranslation))"))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button(String(localized: "Smaller text"), systemImage: "textformat.size.smaller") {
                        textScale = max(0.85, textScale - 0.1)
                    }
                    Button(String(localized: "Larger text"), systemImage: "textformat.size.larger") {
                        textScale = min(1.6, textScale + 0.1)
                    }
                    Button(String(localized: "Default text size")) { textScale = 1 }
                } label: {
                    Label(String(localized: "Text size"), systemImage: "textformat.size")
                }
            }
        }
    }

    private var servingsControl: some View {
        HStack {
            Label(String(localized: "Servings"), systemImage: "person.2")
                .font(.headline)
            Spacer()
            Stepper(
                value: Binding(
                    get: { progress.targetServings },
                    set: { store.setServings($0, for: dish.uuid) }
                ),
                in: 1...50
            ) {
                Text("\(progress.targetServings)")
                    .font(.title2.monospacedDigit())
            }
            .fixedSize()
        }
    }

    private func ingredientButton(_ ingredient: DishIngredient, at index: Int) -> some View {
        let checked = progress.checkedIngredientIndexes.contains(index)
        let name = ingredient.displayName(translated: dish.prefersTranslation) ?? "—"
        let amount = scaler.amountText(for: ingredient)
        return Button {
            store.toggleIngredient(index, for: dish.uuid)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(checked ? .green : .secondary)
                Text(name)
                    .strikethrough(checked)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let amount {
                    Text(amount)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .font(.system(size: 20 * textScale))
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(amount.map { "\(name), \($0)" } ?? name)
        .accessibilityValue(checked ? String(localized: "Checked off") : String(localized: "Not checked off"))
        .accessibilityHint(InteractionWording.checkOffHint)
        .accessibilityAddTraits(checked ? .isSelected : [])
    }
}

@MainActor
private struct SpatialInstructionsView: View {
    let dish: Dish

    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow
    @AppStorage("CookingMode.textScale") private var textScale = 1.0
    @State private var showingManualTimer = false

    private var store: CookingSessionStore { appState.cookingSession }

    private var progress: CookingDishProgress {
        store.session?.dishes.first(where: { $0.id == dish.uuid })
            ?? CookingDishProgress(id: dish.uuid, name: dish.name, targetServings: appState.standardServings)
    }

    private var steps: [CookingStep] {
        CookingRecipe.steps(from: dish.displayRecipeText(translated: dish.prefersTranslation))
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if steps.isEmpty {
                        ContentUnavailableView(
                            String(localized: "No cooking steps"),
                            systemImage: "list.number",
                            description: Text(String(localized: "No instructions have been added to this recipe yet."))
                        )
                    } else {
                        ForEach(steps) { step in
                            stepButton(step)
                                .id(step.id)
                        }
                    }
                }
                .padding(24)
            }
            .onChange(of: progress.currentStep) { _, current in
                withAnimation { proxy.scrollTo(current, anchor: .center) }
            }
        }
        .navigationTitle(String(localized: "Instructions · \(dish.displayName(translated: dish.prefersTranslation))"))
        .safeAreaInset(edge: .bottom) { navigationBar }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button(String(localized: "Add timer"), systemImage: "timer") {
                    showingManualTimer = true
                }
                Menu {
                    Button(String(localized: "Smaller text"), systemImage: "textformat.size.smaller") {
                        textScale = max(0.85, textScale - 0.1)
                    }
                    Button(String(localized: "Larger text"), systemImage: "textformat.size.larger") {
                        textScale = min(1.6, textScale + 0.1)
                    }
                    Button(String(localized: "Default text size")) { textScale = 1 }
                } label: {
                    Label(String(localized: "Text size"), systemImage: "textformat.size")
                }
            }
        }
        .sheet(isPresented: $showingManualTimer) {
            SpatialManualTimerSheet(
                dishName: dish.name,
                stepNumber: progress.currentStep + 1,
                onStart: startManualTimer
            )
        }
    }

    private func stepButton(_ step: CookingStep) -> some View {
        let isCurrent = step.id == progress.currentStep
        return HStack(alignment: .top, spacing: 16) {
            Text("\(step.id + 1)")
                .font(.headline.monospacedDigit())
                .frame(width: 42, height: 42)
                .background(isCurrent ? Color.accentColor : Color.secondary.opacity(0.16), in: Circle())
                .foregroundStyle(isCurrent ? .white : .secondary)
            VStack(alignment: .leading, spacing: 12) {
                Text(step.text)
                    .font(.system(size: (isCurrent ? 25 : 20) * textScale, weight: isCurrent ? .semibold : .regular))
                    .frame(maxWidth: .infinity, alignment: .leading)
                if isCurrent, !step.timers.isEmpty {
                    HStack {
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
        .padding(18)
        .background(isCurrent ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 20))
        .contentShape(Rectangle())
        .onTapGesture {
            store.setCurrentStep(step.id, for: dish.uuid, stepCount: steps.count)
        }
        .opacity(isCurrent ? 1 : 0.62)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(localized: "Step \(step.id + 1). \(step.text)"))
        .accessibilityAddTraits(isCurrent ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint(isCurrent ? String(localized: "Current step") : InteractionWording.jumpToStepHint)
    }

    private var navigationBar: some View {
        HStack(spacing: 18) {
            Button(String(localized: "Previous"), systemImage: "chevron.left") {
                moveStep(by: -1)
            }
            .disabled(progress.currentStep == 0 || steps.isEmpty)
            Spacer()
            Text(steps.isEmpty ? "—" : "\(progress.currentStep + 1) / \(steps.count)")
                .font(.headline.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer()
            Button(String(localized: "Next"), systemImage: "chevron.right") {
                moveStep(by: 1)
            }
            .buttonStyle(.borderedProminent)
            .disabled(steps.isEmpty || progress.currentStep >= steps.count - 1)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .padding(18)
        .background(.regularMaterial)
    }

    private func moveStep(by offset: Int) {
        store.setCurrentStep(progress.currentStep + offset, for: dish.uuid, stepCount: steps.count)
    }

    private func startTimer(_ suggestion: RecipeTimerSuggestion, step: CookingStep) {
        store.startTimer(
            dishID: dish.uuid,
            dishName: dish.name,
            stepNumber: step.id + 1,
            stepText: step.text,
            label: suggestion.label,
            duration: suggestion.duration
        )
        openWindow(value: SpatialCookingWindowRoute.timers)
    }

    private func startManualTimer(label: String, duration: TimeInterval) {
        let step = steps.indices.contains(progress.currentStep) ? steps[progress.currentStep] : nil
        store.startTimer(
            dishID: dish.uuid,
            dishName: dish.name,
            stepNumber: progress.currentStep + 1,
            stepText: step?.text ?? String(localized: "Manual timer"),
            label: label,
            duration: duration
        )
        openWindow(value: SpatialCookingWindowRoute.timers)
    }
}

@MainActor
private struct SpatialTimersView: View {
    @Environment(AppState.self) private var appState
    @State private var showingManualTimer = false

    private var store: CookingSessionStore { appState.cookingSession }

    var body: some View {
        Group {
            if let timers = store.session?.timers, !timers.isEmpty {
                TimelineView(.periodic(from: .now, by: 1)) { timeline in
                    ScrollView {
                        LazyVStack(spacing: 14) {
                            ForEach(timers) { timer in
                                timerCard(timer, at: timeline.date)
                            }
                        }
                        .padding(24)
                    }
                }
            } else {
                ContentUnavailableView(
                    String(localized: "No active timers"),
                    systemImage: "timer",
                    description: Text(String(localized: "Start a suggested timer from the instructions, or add one here."))
                )
            }
        }
        .navigationTitle(String(localized: "Cooking timers"))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(String(localized: "Add timer"), systemImage: "plus") {
                    showingManualTimer = true
                }
            }
        }
        .sheet(isPresented: $showingManualTimer) {
            SpatialManualTimerSheet(
                dishName: currentDishName,
                stepNumber: currentStepNumber,
                onStart: startManualTimer
            )
        }
    }

    private func timerCard(_ timer: CookingTimerState, at date: Date) -> some View {
        let remaining = timer.remaining(at: date)
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: remaining <= 0 ? "alarm.waves.left.and.right.fill" : "timer")
                    .font(.title2)
                    .foregroundStyle(remaining <= 0 ? Color.red : Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(timer.contextLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(timer.label).font(.headline)
                }
                Spacer()
                Text(SpatialCookingGuideView.clockText(remaining))
                    .font(.largeTitle.monospacedDigit())
                    .foregroundStyle(remaining <= 0 ? .red : .primary)
            }
            HStack {
                Button(timer.pausedRemaining == nil ? String(localized: "Pause") : String(localized: "Resume")) {
                    store.pauseOrResumeTimer(timer.id, at: date)
                }
                .buttonStyle(.borderedProminent)
                Button(String(localized: "Cancel"), role: .destructive) {
                    store.cancelTimer(timer.id)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(20)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20))
    }

    private var currentDishName: String {
        store.session?.selectedDish?.name ?? String(localized: "Cooking")
    }

    private var currentStepNumber: Int {
        (store.session?.selectedDish?.currentStep ?? 0) + 1
    }

    private func startManualTimer(label: String, duration: TimeInterval) {
        guard let selected = store.session?.selectedDish else { return }
        store.startTimer(
            dishID: selected.id,
            dishName: selected.name,
            stepNumber: selected.currentStep + 1,
            stepText: String(localized: "Manual timer"),
            label: label,
            duration: duration
        )
    }
}

@MainActor
private struct SpatialManualTimerSheet: View {
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
#endif
