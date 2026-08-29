import SwiftUI
import SwiftData

struct ExportedPDF: Identifiable { let id = UUID(); let url: URL }

@MainActor
struct CalendarHomeView: View {
    @Environment(AppState.self) private var appState
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

    private var focusWeek: Date { anchorWeek ?? CalendarPaginator.normalizedWeek(of: .now) }

    private var calendarStyle: CalendarStyle {
        appState.currentHousehold?.calendarStyle ?? .week
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 16) {
                    Color.clear.frame(height: 1)
                        .onAppear {
                            guard didSettle, let top = anchorWeek else { return }
                            paginator.extendPast()
                            proxy.scrollTo(top, anchor: .top)
                        }

                    ForEach(paginator.weekStarts, id: \.self) { weekStart in
                        WeekSectionView(weekStart: weekStart, style: calendarStyle)
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
        }
        .sheet(item: Binding(get: { applyingTemplateWeek.map { IdentifiableDate(date: $0) } },
                             set: { applyingTemplateWeek = $0?.date })) { wrapper in
            ApplyTemplateSheet(targetWeekStart: wrapper.date)
        }
        .sheet(item: $exportedPDF) { pdf in
            PDFShareSheet(url: pdf.url)
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

    private func goTo(_ date: Date) {
        let day = date.startOfDay
        appState.selectedDate = day
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
