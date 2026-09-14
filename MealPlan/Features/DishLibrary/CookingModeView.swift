import SwiftData
import SwiftUI
import TipKit

/// A distraction-free menu cooking view. The durable state lives on
/// `AppState`, so closing this sheet is an interruption rather than a reset.
@MainActor
struct CookingModeView: View {
    let dish: Dish

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Query(sort: \Dish.name) private var allDishes: [Dish]

    @AppStorage("CookingMode.textScale") private var textScale = 1.0
    /// Mirrors the two cooking columns so the step controls can sit nearest
    /// the cook's dominant hand.
    @AppStorage("CookingMode.leftHandedLayout") private var usesLeftHandedLayout = false
    /// Speak each step aloud as it becomes current. On by default — the whole
    /// point of opening this screen at the stove is not having to look at it.
    @AppStorage("CookingMode.speakSteps") private var speakSteps = true
    /// Listen for spoken commands ("next", "repeat", "start timer"). Off until
    /// the cook turns it on and grants microphone + speech permission.
    @AppStorage("CookingMode.voiceControl") private var voiceControlEnabled = false
    @State private var didEnter = false
    @State private var holdsDisplayAwake = false
    @State private var showingResumePrompt = false
    @State private var showingDishPicker = false
    @State private var showingManualTimer = false
    @State private var narrator = CookingNarrator()
    @State private var voice = CookingVoiceController()
    /// Set when permission was refused, so the toggle can explain itself.
    @State private var micPermissionDenied = false
    /// Cooking follows the recipe view: a household that saved a translation
    /// cooks from it, and "Show original" is one tap away in the toolbar.
    @State private var showsTranslation = false

    private var store: CookingSessionStore { appState.cookingSession }

    private var currentDish: Dish {
        guard let id = store.session?.selectedDishID else { return dish }
        return allDishes.first(where: { $0.uuid == id }) ?? dish
    }

    private var progress: CookingDishProgress {
        store.session?.dishes.first(where: { $0.id == currentDish.uuid })
            ?? CookingDishProgress(id: currentDish.uuid, name: currentDish.name, targetServings: appState.standardServings)
    }

    private var steps: [CookingStep] {
        CookingRecipe.steps(from: currentDish.displayRecipeText(translated: showsTranslation))
    }

    private var currentStepText: String? {
        let index = progress.currentStep
        return steps.indices.contains(index) ? steps[index].text : nil
    }

    private var ingredientGroups: [CookingIngredientGroup] {
        CookingRecipe.ingredientGroups(
            ingredientNames: currentDish.sortedIngredients.map {
                $0.displayName(translated: showsTranslation) ?? ""
            },
            steps: steps
        )
    }

    private var hasStepIngredientGroups: Bool {
        ingredientGroups.contains { $0.stepID != nil }
    }

    /// BCP-47 tag for the text currently on screen, so a German recipe isn't
    /// read aloud with an English accent.
    private var narrationLanguageCode: String? {
        showsTranslation ? currentDish.translationLanguageCode : currentDish.recipeLanguageCode
    }

    private var scaler: ServingScaler {
        ServingScaler(
            baseServings: currentDish.servings,
            targetServings: progress.targetServings,
            system: appState.unitSystem,
            roundsAmounts: appState.roundsDisplayedAmounts
        )
    }

    var body: some View {
        GeometryReader { geometry in
            if CookingModeLayoutPolicy.usesSideBySideLayout(
                in: geometry.size,
                horizontalSizeClass: horizontalSizeClass,
                verticalSizeClass: verticalSizeClass
            ) {
                landscapeContent
            } else {
                portraitContent
            }
        }
        .navigationTitle(currentDish.displayName(translated: showsTranslation))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar { cookingToolbar }
        .safeAreaInset(edge: .bottom) { listeningIndicator }
        .onAppear {
            enterCookingMode()
            showsTranslation = currentDish.prefersTranslation
            voice.onCommand = { command in handle(command) }
            if voiceControlEnabled { Task { await startVoiceControl(requesting: false) } }
            speakCurrentStep(force: false)
        }
        .onChange(of: currentDish.uuid) { _, _ in
            showsTranslation = currentDish.prefersTranslation
            speakCurrentStep(force: false)
        }
        .onChange(of: progress.currentStep) { _, _ in
            speakCurrentStep(force: false)
        }
        .onChange(of: voiceControlEnabled) { _, enabled in
            if enabled {
                MealPlanTips.recordVoiceControlTurnedOn()
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
            releaseDisplayAwake()
            narrator.stop()
            voice.stop()
        }
        .alert(String(localized: "Microphone access is off"), isPresented: $micPermissionDenied) {
            Button(String(localized: "OK"), role: .cancel) {}
        } message: {
            Text(String(localized: "To use hands-free voice control, allow microphone and speech recognition for MealPlan in Settings."))
        }
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

    private var portraitContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                handsFreeTip
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
    }

    /// iPhone landscape keeps the two things a cook cross-references visible
    /// at once. Each pane scrolls independently, so a long ingredient list
    /// never pushes the current instruction or its controls off screen.
    private var landscapeContent: some View {
        VStack(spacing: 0) {
            landscapeSessionBar
            Divider()
            HStack(spacing: 0) {
                if usesLeftHandedLayout {
                    ingredientPane
                    Divider()
                    instructionPane
                } else {
                    instructionPane
                    Divider()
                    ingredientPane
                }
            }
        }
        // The NavigationStack and sheet already provide the device's safe
        // area. Keeping all content inside this geometry makes the columns
        // avoid both the camera cutout and the home indicator in landscape.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var instructionPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                handsFreeTip
                directions
                if !(store.session?.timers.isEmpty ?? true) { activeTimers }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var ingredientPane: some View {
        ScrollViewReader { proxy in
            ScrollView {
                ingredients
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: progress.currentStep) { _, step in
                withAnimation(.snappy) {
                    proxy.scrollTo(CookingIngredientGroup(stepID: step, ingredientIndexes: []).id, anchor: .top)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var handsFreeTip: some View {
        // Inline rather than a popover on the Voice menu: on iPhone that menu
        // lives in the toolbar's overflow, where a popover has no anchor.
        if voice.isAvailable, !voiceControlEnabled {
            InlineTip(tip: HandsFreeCookingTip()) { action in
                if action.id == HandsFreeCookingTip.turnOnActionID {
                    voiceControlEnabled = true
                }
            }
        }
    }

    /// A single compact row leaves the limited landscape height to the recipe.
    private var landscapeSessionBar: some View {
        HStack(spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(store.session?.dishes ?? []) { item in
                        if item.id == currentDish.uuid {
                            Button(label(for: item)) { store.select(item.id) }
                                .buttonStyle(.borderedProminent)
                        } else {
                            Button(label(for: item)) { store.select(item.id) }
                                .buttonStyle(.bordered)
                        }
                    }
                }
            }

            Button {
                showingDishPicker = true
            } label: {
                Label(String(localized: "Add dish"), systemImage: "plus")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel(String(localized: "Add dish"))

            Divider().frame(height: 28)

            Stepper(value: servingsBinding, in: 1...50) {
                Text(String(localized: "\(progress.targetServings) servings"))
                    .font(.callout)
                    .monospacedDigit()
            }
            .fixedSize()
        }
        .controlSize(.small)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }

    @ToolbarContentBuilder
    private var cookingToolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button(String(localized: "Close")) { dismiss() }
        }
        ToolbarItemGroup(placement: .secondaryAction) {
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
                Divider()
                Toggle(isOn: $usesLeftHandedLayout) {
                    Label(String(localized: "Left-handed layout"), systemImage: "hand.raised")
                }
            } label: {
                Label(String(localized: "Display"), systemImage: "rectangle.split.2x1")
            }
            Menu {
                Toggle(String(localized: "Read steps aloud"), isOn: $speakSteps)
                Button(String(localized: "Repeat this step"), systemImage: "arrow.clockwise") {
                    speakCurrentStep(force: true)
                }
                .disabled(currentStepText == nil)
                if voice.isAvailable {
                    Divider()
                    Toggle(String(localized: "Hands-free voice control"), isOn: $voiceControlEnabled)
                    if voiceControlEnabled {
                        Text(String(localized: "Say “next”, “back”, “repeat” or “start timer”."))
                    }
                }
            } label: {
                Label(
                    String(localized: "Voice"),
                    systemImage: voice.isListening ? "waveform.circle.fill" : "speaker.wave.2"
                )
            }
            if currentDish.hasSavedTranslation {
                Button(
                    showsTranslation
                        ? String(localized: "Show original")
                        : String(localized: "Show translation"),
                    systemImage: "translate"
                ) {
                    showsTranslation.toggle()
                }
            }
        }
        ToolbarItem(placement: .confirmationAction) {
            Button(String(localized: "Finish session")) {
                narrator.stop()
                voice.stop()
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
                            Button(label(for: item)) { store.select(item.id) }
                                .buttonStyle(.borderedProminent)
                        } else {
                            Button(label(for: item)) { store.select(item.id) }
                                .buttonStyle(.bordered)
                        }
                    }
                }
            }
        }
    }

    /// The session remembers the name a dish had when cooking started; this
    /// shows the wording that is on screen for the rest of the recipe.
    private func label(for item: CookingDishProgress) -> String {
        guard let dish = allDishes.first(where: { $0.uuid == item.id }) else { return item.name }
        return dish.displayName(translated: showsTranslation)
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
            } else if hasStepIngredientGroups {
                ForEach(ingredientGroups) { group in
                    ingredientGroup(group)
                        .id(group.id)
                }
            } else {
                ForEach(Array(currentDish.sortedIngredients.enumerated()), id: \.offset) { index, line in
                    ingredientRow(index: index, line: line)
                    Divider()
                }
            }
        }
    }

    private func ingredientGroup(_ group: CookingIngredientGroup) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ingredientGroupHeader(group)
            ForEach(group.ingredientIndexes, id: \.self) { index in
                if currentDish.sortedIngredients.indices.contains(index) {
                    ingredientRow(index: index, line: currentDish.sortedIngredients[index])
                    if index != group.ingredientIndexes.last { Divider() }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background {
            RoundedRectangle(cornerRadius: 14)
                .fill(group.stepID == progress.currentStep ? Color.accentColor.opacity(0.10) : Color.secondary.opacity(0.06))
        }
    }

    @ViewBuilder
    private func ingredientGroupHeader(_ group: CookingIngredientGroup) -> some View {
        if let stepID = group.stepID, let step = steps.first(where: { $0.id == stepID }) {
            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "Step \(step.id + 1)"))
                    .font(.headline)
                        .foregroundStyle(
                            group.stepID == progress.currentStep ? Color.accentColor : Color.secondary
                        )
                Text(step.text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .padding(.bottom, 6)
        } else {
            Text(String(localized: "Other ingredients"))
                .font(.headline)
                .foregroundStyle(.secondary)
                .padding(.bottom, 6)
        }
    }

    private func ingredientRow(index: Int, line: DishIngredient) -> some View {
        let checked = progress.checkedIngredientIndexes.contains(index)
        let name = line.displayName(translated: showsTranslation) ?? "—"
        let amount = scaler.amountText(for: line)

        return Button {
            withAnimation(.snappy) {
                store.toggleIngredient(index, for: currentDish.uuid)
            }
        } label: {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(checked ? .green : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .strikethrough(checked)
                    if let note = line.displayNote(translated: showsTranslation), !note.isEmpty {
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .strikethrough(checked)
                    }
                }
                Spacer(minLength: 8)
                if let amount {
                    Text(amount).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            .font(.title3)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
            .opacity(checked ? 0.62 : 1)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(amount.map { "\(name), \($0)" } ?? name)
        .accessibilityValue(checked
            ? String(localized: "Checked off")
            : String(localized: "Not checked off"))
        .accessibilityHint(InteractionWording.checkOffHint)
        .accessibilityAddTraits(checked ? .isSelected : [])
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
                            .minimumScaleFactor(0.6)
                            .lineLimit(1)
                            .frame(width: 38, height: 38)
                            .background(isCurrent ? Color.accentColor : Color.secondary.opacity(0.14), in: Circle())
                            .foregroundStyle(isCurrent ? .white : .secondary)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 12) {
                            Text(step.text)
                                // Scales with the system Dynamic Type setting
                                // *and* the in-view text-size control.
                                .font(.system(
                                    size: (isCurrent ? 25 : 20) * textScale,
                                    weight: isCurrent ? .semibold : .regular
                                ))
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
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(String(localized: "Step \(step.id + 1). \(step.text)"))
                    .accessibilityAddTraits(isCurrent ? [.isButton, .isSelected] : .isButton)
                    .accessibilityHint(isCurrent
                        ? String(localized: "Current step")
                        : InteractionWording.jumpToStepHint)
                }

                HStack(spacing: 12) {
                    if usesLeftHandedLayout {
                        nextStepButton
                        Spacer(minLength: 0)
                        previousStepButton
                    } else {
                        previousStepButton
                        Spacer(minLength: 0)
                        nextStepButton
                    }
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var previousStepButton: some View {
        Button(String(localized: "Previous"), systemImage: "chevron.left") {
            store.setCurrentStep(progress.currentStep - 1, for: currentDish.uuid, stepCount: steps.count)
        }
        .disabled(progress.currentStep == 0)
    }

    private var nextStepButton: some View {
        Button(String(localized: "Next"), systemImage: "chevron.right") {
            store.setCurrentStep(progress.currentStep + 1, for: currentDish.uuid, stepCount: steps.count)
        }
        .disabled(progress.currentStep >= steps.count - 1)
    }

    private var activeTimers: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(String(localized: "Timers")).font(.title2.bold())
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                VStack(spacing: 10) {
                    ForEach(store.session?.timers ?? []) { timer in
                        let remaining = timer.remaining(at: timeline.date)
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 12) {
                                timerDetails(timer, remaining: remaining)
                                Spacer(minLength: 8)
                                timerButtons(timer, at: timeline.date)
                            }
                            VStack(alignment: .leading, spacing: 10) {
                                timerDetails(timer, remaining: remaining)
                                timerButtons(timer, at: timeline.date)
                            }
                        }
                        .padding(12)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                    }
                }
            }
        }
    }

    private func timerDetails(_ timer: CookingTimerState, remaining: TimeInterval) -> some View {
        HStack(spacing: 10) {
            Image(systemName: remaining <= 0 ? "alarm.waves.left.and.right.fill" : "timer")
                .foregroundStyle(remaining <= 0 ? .red : .accentColor)
            VStack(alignment: .leading) {
                Text(timer.contextLabel).font(.caption).foregroundStyle(.secondary)
                Text(timer.label).font(.headline)
                Text(clockText(remaining)).font(.title2.monospacedDigit())
            }
        }
    }

    private func timerButtons(_ timer: CookingTimerState, at date: Date) -> some View {
        HStack(spacing: 8) {
            Button(timer.pausedRemaining == nil ? String(localized: "Pause") : String(localized: "Resume")) {
                store.pauseOrResumeTimer(timer.id, at: date)
            }
            Button(String(localized: "Cancel"), role: .destructive) {
                store.cancelTimer(timer.id)
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

    // MARK: - Voice

    /// A slim banner pinned above the home indicator while the recogniser is
    /// armed, so a VoiceOver user (and everyone else) knows the mic is live.
    @ViewBuilder
    private var listeningIndicator: some View {
        if voice.isListening {
            HStack(spacing: 8) {
                Image(systemName: "mic.fill")
                    .foregroundStyle(.tint)
                    .symbolEffect(.variableColor.iterative, isActive: true)
                Text(voice.lastHeard.isEmpty
                     ? String(localized: "Listening for “next”, “back”, “repeat”…")
                     : voice.lastHeard)
                    .font(.callout)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(.bar)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(String(localized: "Voice control is listening"))
            .accessibilityAddTraits(.updatesFrequently)
        }
    }

    /// Speaks the current step. `force` is the "repeat" affordance; otherwise it
    /// respects the "Read steps aloud" switch.
    private func speakCurrentStep(force: Bool) {
        guard force || speakSteps else { return }
        guard let text = currentStepText else {
            if force { narrator.stop() }
            return
        }
        narrator.languageCode = narrationLanguageCode
        narrator.audioSessionManagedExternally = voice.isListening
        let ordinal = String(localized: "Step \(progress.currentStep + 1)")
        narrator.speak("\(ordinal). \(text)")
    }

    private func startVoiceControl(requesting: Bool) async {
        if requesting {
            let granted = await voice.requestAuthorization()
            guard granted else {
                voiceControlEnabled = false
                micPermissionDenied = true
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
            store.setCurrentStep(progress.currentStep + 1, for: currentDish.uuid, stepCount: steps.count)
        case .back:
            store.setCurrentStep(progress.currentStep - 1, for: currentDish.uuid, stepCount: steps.count)
        case .repeatStep:
            speakCurrentStep(force: true)
        case .startTimer:
            let index = progress.currentStep
            if steps.indices.contains(index), let suggestion = steps[index].timers.first {
                startTimer(suggestion, step: steps[index])
            } else {
                showingManualTimer = true
            }
        case .stop:
            voiceControlEnabled = false
        }
    }

    private func enterCookingMode() {
        guard !didEnter else { return }
        didEnter = true
        MealPlanTips.recordCookingModeOpened()
        // Someone who turned it on before tips existed has found it already.
        if voiceControlEnabled { MealPlanTips.recordVoiceControlTurnedOn() }
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

/// Geometry-based because iPhones keep a compact horizontal size class in
/// both orientations. Requiring compact height avoids turning iPad and Mac
/// windows into the phone-specific cooking layout simply because they are wide.
enum CookingModeLayoutPolicy {
    static let minimumSideBySideWidth: Double = 620

    static func usesSideBySideLayout(
        in size: CGSize,
        horizontalSizeClass: UserInterfaceSizeClass?,
        verticalSizeClass: UserInterfaceSizeClass?
    ) -> Bool {
        horizontalSizeClass == .compact
            && verticalSizeClass == .compact
            && size.width > size.height
            && size.width >= minimumSideBySideWidth
    }
}

#Preview {
    NavigationStack { CookingModeView(dish: PreviewData.household.dishes?.first ?? Dish(name: "Test")) }
        .environment(AppState.preview)
        .modelContainer(PreviewData.container)
}
