import SwiftUI
import SwiftData

struct ExportedPDF: Identifiable { let id = UUID(); let url: URL }

@MainActor
struct CalendarHomeView: View {
    @Environment(AppState.self) private var appState
    @Environment(PurchaseManager.self) private var purchaseManager
    @Environment(\.modelContext) private var context
    @Query(sort: [SortDescriptor(\MealType.sortOrder), SortDescriptor(\MealType.name)])
    private var mealTypes: [MealType]
    @Query(sort: [SortDescriptor(\MealPlanEntry.date), SortDescriptor(\MealPlanEntry.sortIndex)])
    private var planEntries: [MealPlanEntry]
    /// The Monday-based week sitting at the top of the plan. Written by the
    /// scroll view only when it actually changes weeks, so ordinary scrolling
    /// no longer re-runs this body — and with it the week grouping over every
    /// planned meal in the store.
    @State private var focusWeek = CalendarPaginator.normalizedWeek(of: .now)
    @State private var showingDatePicker = false
    @State private var jumpDate = Date.now
    @State private var jumpTarget: Date?
    @State private var savingTemplateWeek: Date?
    @State private var applyingTemplateWeek: Date?
    @State private var printingWeek: Date?
    @State private var showingPaywall = false
    @State private var showingMealsSettings = false
    /// Kept separate from `AppState`: day visibility changes rapidly during a
    /// scroll and only the small week strip needs to observe them. If this
    /// lives on the app state, every change invalidates the whole calendar.
    @State private var visibilityTracker = PlanVisibilityTracker()
    /// First day of the week shown in the strip above the plan. Follows the
    /// user's locale, unlike the Monday-based week sections below it.
    @State private var stripWeekStart: Date = Date.now.startOfWeek(calendar: .current)

    var body: some View {
        VStack(spacing: 0) {
            // No `.id(stripWeekStart)` here: it used to force a full teardown
            // and refetch of the strip on every week the plan scrolled past.
            // The strip now takes its week's meals as a plain value instead of
            // querying them itself, so it simply updates — and animates.
            TrackedWeekStrip(
                weekStart: $stripWeekStart,
                selectedDate: appState.selectedDate,
                visibilityTracker: visibilityTracker,
                entries: stripEntries,
                mealTypes: mealTypes,
                onDropDish: { references, day in drop(references, on: day) }
            ) { day in
                goTo(day)
            }
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
            printPlan: { printingWeek = focusWeek }
        ))
    }

    /// The scrolling list of week sections below the week strip.
    private var plan: some View {
        // One live query feeds the whole lazy calendar. A query in every week
        // makes SwiftData install and update many fetch observers while the
        // scroll view is creating and recycling sections.
        //
        // The grouping happens here, above `PlanScrollView`, on purpose: the
        // scroll position changes many times a second and lives inside that
        // child, so it no longer drags a pass over every planned meal in the
        // store along with it.
        let entriesByWeek = Dictionary(grouping: planEntries) {
            CalendarPaginator.normalizedWeek(of: $0.date)
        }

        return PlanScrollView(
            entriesByWeek: entriesByWeek,
            mealTypes: mealTypes,
            jumpTarget: $jumpTarget,
            onDayVisibilityChange: { visible, dayID in
                visibilityTracker.setDayVisible(visible, id: dayID)
            },
            onFocusWeekChange: { week in
                focusWeek = week
                let localeWeek = week.startOfWeek(calendar: .current)
                if localeWeek != stripWeekStart { stripWeekStart = localeWeek }
            }
        )
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
                Button(String(localized: "Print plan…"), systemImage: "printer") {
                    printingWeek = focusWeek
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
        .sheet(item: Binding(get: { printingWeek.map { IdentifiableDate(date: $0) } },
                             set: { printingWeek = $0?.date })) { wrapper in
            PrintPlanSheet(referenceWeek: wrapper.date)
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
        focusWeek = CalendarPaginator.normalizedWeek(of: day)
        // `PlanScrollView` owns the paginator, so it loads the week and does
        // the scrolling; this only says where to go.
        jumpTarget = day
    }

    /// The strip's own week, cut out of the one store-wide query. The plan's
    /// sections are Monday-based while the strip follows the user's locale, so
    /// this is a separate slice rather than one of the week buckets.
    private var stripEntries: [MealPlanEntry] {
        let end = stripWeekStart.adding(days: 7)
        return planEntries.filter { $0.date >= stripWeekStart && $0.date < end }
    }
}

/// The plan's lazy, endlessly-growing list of weeks.
///
/// Kept apart from `CalendarHomeView` so that the scroll position — which is
/// written on nearly every frame the user drags — only invalidates this view.
/// Living on the calendar itself, it re-ran the week strip, the toolbar, every
/// sheet modifier and a grouping pass over the whole plan on each of those
/// writes.
@MainActor
private struct PlanScrollView: View {
    let entriesByWeek: [Date: [MealPlanEntry]]
    let mealTypes: [MealType]
    /// A day the calendar wants brought into view; cleared once handled.
    @Binding var jumpTarget: Date?
    var onDayVisibilityChange: (Bool, String) -> Void
    /// Reports the Monday-based week at the top, only when it changes.
    var onFocusWeekChange: (Date) -> Void

    @State private var paginator = CalendarPaginator()
    @State private var anchorWeek: Date? = CalendarPaginator.normalizedWeek(of: .now)
    @State private var didSettle = false

    /// How close to either end of the loaded window the top week may come
    /// before more weeks are loaded. Growing this early is the point: the
    /// window used to be extended by a one-point spacer that only appeared
    /// once the user had already scrolled onto it, so every few weeks the plan
    /// ran into a wall and waited for a batch of sections to be built.
    private static let prefetchDistance = 3

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 16) {
                    ForEach(paginator.weekStarts, id: \.self) { weekStart in
                        WeekSectionView(
                            weekStart: weekStart,
                            style: .week,
                            mealTypes: mealTypes,
                            entries: entriesByWeek[weekStart] ?? [],
                            onDayVisibilityChange: onDayVisibilityChange
                        )
                            .id(weekStart)
                    }
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
            .onChange(of: anchorWeek) { _, week in
                guard let week else { return }
                onFocusWeekChange(week)
                guard didSettle else { return }
                extendWindow(around: week, proxy: proxy)
            }
        }
    }

    /// Loads more weeks while the user is still a few sections away from the
    /// end of the window, so the plan never stalls at a boundary.
    private func extendWindow(around week: Date, proxy: ScrollViewProxy) {
        guard let index = paginator.weekStarts.firstIndex(of: week) else { return }

        if index >= paginator.weekStarts.count - Self.prefetchDistance {
            // Appending leaves everything already laid out where it is.
            paginator.extendFuture()
        }

        if index < Self.prefetchDistance {
            // Prepending changes every existing view's vertical position. Wait
            // for that layout update, then restore the week that was at the
            // top without an animation, so the content under the finger stays
            // put instead of snapping to a new position.
            withTransaction(Transaction(animation: nil)) {
                paginator.extendPast()
            }
            Task { @MainActor in
                await Task.yield()
                withTransaction(Transaction(animation: nil)) {
                    proxy.scrollTo(week, anchor: .top)
                }
            }
        }
    }

    /// Puts `date`'s day card at the very top of the scroll view. The week
    /// section is scrolled to first so the lazy stack materializes it — the day
    /// ids only exist once their section is built.
    private func scrollToDay(_ date: Date, proxy: ScrollViewProxy) async {
        let day = date.startOfDay
        let week = paginator.ensureLoaded(day)
        // Writing the bound scroll position is itself a scroll: it is what
        // reaches a week that was only just added to the window, which
        // `scrollTo` alone cannot do while the section has yet to be built.
        anchorWeek = week
        proxy.scrollTo(week, anchor: .top)
        try? await Task.sleep(for: .milliseconds(50))
        proxy.scrollTo(day.dayID, anchor: .top)
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
    let entries: [MealPlanEntry]
    let mealTypes: [MealType]
    var onDropDish: ([DishReference], Date) -> Bool
    var onSelect: (Date) -> Void

    var body: some View {
        WeekStripView(
            weekStart: $weekStart,
            selectedDate: selectedDate,
            visibleDayIDs: visibilityTracker.visibleDayIDs,
            entries: entries,
            mealTypes: mealTypes,
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
