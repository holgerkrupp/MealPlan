import SwiftUI
import SwiftData

struct ExportedPDF: Identifiable { let id = UUID(); let url: URL }

@MainActor
struct CalendarHomeView: View {
    @Environment(AppState.self) private var appState
    @Environment(PurchaseManager.self) private var purchaseManager
    @Environment(\.modelContext) private var context
    @State private var paginator = CalendarPaginator()
    @State private var anchorWeek: Date? = CalendarPaginator.normalizedWeek(of: .now)
    @State private var didSettle = false
    @State private var showingDatePicker = false
    @State private var jumpDate = Date.now
    @State private var jumpTarget: Date?
    @State private var savingTemplateWeek: Date?
    @State private var applyingTemplateWeek: Date?
    @State private var exportedPDF: ExportedPDF?
    @State private var showingPaywall = false
    @State private var showingMealsSettings = false
    /// Kept separate from `AppState`: day visibility changes rapidly during a
    /// scroll and only the small week strip needs to observe them. If this
    /// lives on the app state, every change invalidates the whole calendar.
    @State private var visibilityTracker = PlanVisibilityTracker()
    /// First day of the week shown in the strip above the plan. Follows the
    /// user's locale, unlike the Monday-based week sections below it.
    @State private var stripWeekStart: Date = Date.now.startOfWeek(calendar: .current)

    private var focusWeek: Date { anchorWeek ?? CalendarPaginator.normalizedWeek(of: .now) }

    var body: some View {
        VStack(spacing: 0) {
            TrackedWeekStrip(
                weekStart: $stripWeekStart,
                selectedDate: appState.selectedDate,
                visibilityTracker: visibilityTracker,
                onDropDish: { references, day in drop(references, on: day) }
            ) { day in
                goTo(day)
            }
            .id(stripWeekStart)
            .padding(.horizontal, 12)
            .padding(.top, 4)
            .padding(.bottom, 8)
            .background(.bar)

            Divider()

            if let latestFreeDate = purchaseManager.latestPlanningDate() {
                Button { showingPaywall = true } label: {
                    Label {
                        Text(String(localized: "Free planning through \(latestFreeDate.formatted(date: .abbreviated, time: .omitted)). Unlock for later dates."))
                    } icon: {
                        Image(systemName: "lock.open")
                    }
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .background(.bar)
            }

            plan
        }
        // The Plan menu only works while the calendar is on screen; switching
        // to another section drops this value and greys the menu out.
        .focusedSceneValue(\.planCommands, PlanCommands(
            goToToday: { goTo(.now) },
            jumpToDate: {
                jumpDate = appState.selectedDate
                showingDatePicker = true
            },
            goToPreviousWeek: { goTo(appState.selectedDate.adding(days: -7)) },
            goToNextWeek: { goTo(appState.selectedDate.adding(days: 7)) },
            saveWeekAsTemplate: { savingTemplateWeek = focusWeek },
            applyTemplate: { applyingTemplateWeek = focusWeek },
            exportWeekPDF: { exportPDF() }
        ))
    }

    /// The scrolling list of week sections below the week strip.
    private var plan: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 16) {
                    Color.clear.frame(height: 1)
                        .onAppear {
                            guard didSettle, let top = anchorWeek else { return }
                            // Prepending weeks changes every existing view's
                            // vertical position. Wait for that layout update,
                            // then restore the old first week without an
                            // animation so the content under the finger stays
                            // put instead of snapping to a new position.
                            withTransaction(Transaction(animation: nil)) {
                                paginator.extendPast()
                            }
                            Task { @MainActor in
                                await Task.yield()
                                withTransaction(Transaction(animation: nil)) {
                                    proxy.scrollTo(top, anchor: .top)
                                }
                            }
                        }

                    ForEach(paginator.weekStarts, id: \.self) { weekStart in
                        WeekSectionView(
                            weekStart: weekStart,
                            style: .week,
                            onDayVisibilityChange: { visible, dayID in
                                visibilityTracker.setDayVisible(visible, id: dayID)
                            }
                        )
                            .id(weekStart)
                    }

                    Color.clear.frame(height: 1)
                        .onAppear { if didSettle { paginator.extendFuture() } }
                }
                .scrollTargetLayout()
            }
            .scrollPosition(id: $anchorWeek, anchor: .top)
            .task {
                try? await Task.sleep(for: .milliseconds(350))
                await scrollToDay(.now, proxy: proxy)
                try? await Task.sleep(for: .milliseconds(250))
                didSettle = true
            }
            .onChange(of: jumpTarget) { _, target in
                guard let target else { return }
                jumpTarget = nil
                Task { await scrollToDay(target, proxy: proxy) }
            }
            // Keep the strip on the week the user scrolled the plan to.
            .onChange(of: anchorWeek) { _, week in
                guard let week else { return }
                let localeWeek = week.startOfWeek(calendar: .current)
                if localeWeek != stripWeekStart { stripWeekStart = localeWeek }
            }
        }
        .navigationTitle(appState.currentHousehold?.name ?? "MealPlan")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(String(localized: "Today")) { goTo(.now) }
            }
            ToolbarItem(placement: .secondaryAction) {
                Button(String(localized: "Jump to date…"), systemImage: "calendar") {
                    jumpDate = appState.selectedDate
                    showingDatePicker = true
                }
            }
            ToolbarItem(placement: .secondaryAction) {
                Button(String(localized: "Configure meals…"), systemImage: "fork.knife") {
                    showingMealsSettings = true
                }
            }
            ToolbarItem(placement: .secondaryAction) {
                Menu(String(localized: "This week"), systemImage: "square.on.square") {
                    Button(String(localized: "Save week as template"), systemImage: "square.and.arrow.down") {
                        savingTemplateWeek = focusWeek
                    }
                    Button(String(localized: "Apply a template…"), systemImage: "square.on.square.dashed") {
                        applyingTemplateWeek = focusWeek
                    }
                    Button(String(localized: "Export week as PDF"), systemImage: "doc.richtext") {
                        exportPDF()
                    }
                }
            }
        }
        .sheet(item: Binding(get: { savingTemplateWeek.map { IdentifiableDate(date: $0) } },
                             set: { savingTemplateWeek = $0?.date })) { wrapper in
            SaveTemplateSheet(weekStart: wrapper.date)
                .dismissesOnOutsideClick()
        }
        .sheet(item: Binding(get: { applyingTemplateWeek.map { IdentifiableDate(date: $0) } },
                             set: { applyingTemplateWeek = $0?.date })) { wrapper in
            ApplyTemplateSheet(targetWeekStart: wrapper.date)
                .dismissesOnOutsideClick()
        }
        .sheet(item: $exportedPDF) { pdf in
            PDFShareSheet(url: pdf.url)
                .dismissesOnOutsideClick()
        }
        .sheet(isPresented: $showingPaywall) {
            PaywallView()
                .dismissesOnOutsideClick()
        }
        .sheet(isPresented: $showingMealsSettings) {
            NavigationStack {
                MealsSettingsView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button(String(localized: "Done")) { showingMealsSettings = false }
                        }
                    }
            }
            .dismissesOnOutsideClick()
        }
        .sheet(isPresented: $showingDatePicker) {
            NavigationStack {
                DatePicker(
                    String(localized: "Jump to date"),
                    selection: $jumpDate,
                    displayedComponents: .date
                )
                .datePickerStyle(.graphical)
                .padding()
                .navigationTitle(String(localized: "Jump to date"))
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(String(localized: "Go")) {
                            showingDatePicker = false
                            goTo(jumpDate)
                        }
                    }
                    ToolbarItem(placement: .cancellationAction) {
                        Button(String(localized: "Cancel")) { showingDatePicker = false }
                    }
                }
            }
            .presentationDetents([.medium])
            .dismissesOnOutsideClick()
        }
        .overlay(alignment: .bottom) {
            if let offer = appState.undoOffer {
                UndoBanner(offer: offer) { appState.undoOffer = nil }
                    .padding()
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: appState.undoOffer?.id)
    }

    /// A meal dragged onto the week strip moves to that day and keeps the meal
    /// it was planned in; the plan then scrolls there so the move is visible.
    /// This is how a meal reaches a week that isn't on screen — the plan only
    /// scrolls under a drag on iOS, and not at all on the Mac.
    private func drop(_ references: [DishReference], on day: Date) -> Bool {
        guard !appState.isGuest, let reference = references.first else { return false }
        guard purchaseManager.canPlan(on: day) else {
            showingPaywall = true
            return false
        }
        let accepted = MealPlanner.drop(
            reference, onto: day, mealKey: nil,
            household: appState.currentHousehold,
            memberName: appState.currentMemberName,
            context: context
        )
        if accepted { goTo(day) }
        return accepted
    }

    private func goTo(_ date: Date) {
        let day = date.startOfDay
        appState.selectedDate = day
        stripWeekStart = day.startOfWeek(calendar: .current)
        anchorWeek = paginator.ensureLoaded(day)
        jumpTarget = day
    }

    /// Puts `date`'s day card at the very top of the scroll view. The week
    /// section is scrolled to first so the lazy stack materializes it — the day
    /// ids only exist once their section is built.
    private func scrollToDay(_ date: Date, proxy: ScrollViewProxy) async {
        let day = date.startOfDay
        proxy.scrollTo(CalendarPaginator.normalizedWeek(of: day), anchor: .top)
        try? await Task.sleep(for: .milliseconds(50))
        proxy.scrollTo(day.dayID, anchor: .top)
    }

    private func exportPDF() {
        let data = WeekExport.data(
            forWeekContaining: focusWeek,
            householdName: appState.currentHousehold?.name ?? "MealPlan",
            context: context
        )
        if let url = WeekExport.pdf(data) {
            exportedPDF = ExportedPDF(url: url)
        }
    }
}

/// The rapidly changing scroll visibility state is observed only here. This
/// keeps the planner's lazy stack, queries, and meal cards out of the update
/// path while the glass pill moves across the week strip.
@Observable
@MainActor
private final class PlanVisibilityTracker {
    private(set) var visibleDayIDs: Set<String> = []

    func setDayVisible(_ visible: Bool, id: String) {
        if visible {
            visibleDayIDs.insert(id)
        } else {
            visibleDayIDs.remove(id)
        }
    }
}

@MainActor
private struct TrackedWeekStrip: View {
    @Binding var weekStart: Date
    let selectedDate: Date
    let visibilityTracker: PlanVisibilityTracker
    var onDropDish: ([DishReference], Date) -> Bool
    var onSelect: (Date) -> Void

    var body: some View {
        WeekStripView(
            weekStart: $weekStart,
            selectedDate: selectedDate,
            visibleDayIDs: visibilityTracker.visibleDayIDs,
            onDropDish: onDropDish,
            onSelect: onSelect
        )
    }
}

struct IdentifiableDate: Identifiable { let id = UUID(); let date: Date }

@MainActor
struct PDFShareSheet: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Image(systemName: "doc.richtext")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                Text(String(localized: "Your week is ready as a PDF."))
                ShareLink(item: url) {
                    Label(String(localized: "Share / Print"), systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
            .navigationTitle(String(localized: "Week PDF"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Done")) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

@MainActor
struct UndoBanner: View {
    let offer: AppState.UndoOffer
    var dismiss: () -> Void

    var body: some View {
        HStack {
            Text(offer.message)
                .foregroundStyle(.white)
            Spacer()
            Button(String(localized: "Undo")) {
                offer.action()
                dismiss()
            }
            .foregroundStyle(.white)
            .fontWeight(.semibold)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.black.opacity(0.85), in: Capsule())
        .task {
            try? await Task.sleep(for: .seconds(5))
            dismiss()
        }
    }
}

#Preview {
    NavigationStack { CalendarHomeView() }
        .environment(AppState.preview)
        .modelContainer(PreviewData.container)
}

#Preview("Week PDF") {
    PDFShareSheet(url: URL(fileURLWithPath: "/tmp/MealPlan-Woche.pdf"))
}

#Preview("Undo banner") {
    UndoBanner(offer: AppState.UndoOffer(message: String(localized: "Meal removed"), action: {})) {}
        .padding()
}
