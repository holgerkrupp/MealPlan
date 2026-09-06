import UniformTypeIdentifiers
import SwiftData
import SwiftUI

/// The print dialog: pick the days, the paper and how much nutrition to carry,
/// see the first sheet, then print or save it.
///
/// Every choice here is written back to `UserDefaults` as it changes, so the
/// second time someone prints the fridge sheet it is already set up the way
/// they left it and printing is two taps: open, print.
@MainActor
struct PrintPlanSheet: View {
    /// The week the planner is showing, which "the week shown" and "next week"
    /// are relative to.
    let referenceWeek: Date
    /// What to print when the sheet opens, overriding what was printed last
    /// time. Set by the Shopping screen, whose Print… means the list.
    var initialContent: PrintContent?

    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var settings = MealPlanPrintSettings.load()
    /// Only the *length* of a custom span is remembered; the start is picked
    /// fresh each time, defaulting to today. See `PrintSpan`.
    @State private var customStart = Date.now.startOfDay
    @State private var document: MealPlanPrintDocument?
    @State private var exportedPDF: ExportedPDF?
    @State private var savedPDF: Data?
    @State private var showingSavePanel = false
    @State private var errorMessage: String?
    @State private var isRendering = false

    private var range: DayRange {
        settings.span.range(
            reference: referenceWeek,
            customStart: customStart,
            customDayCount: settings.customDayCount
        )
    }

    private var geometry: PrintPageGeometry {
        PrintPageGeometry(paper: settings.paper, orientation: settings.orientation)
    }

    private var pageCount: Int {
        guard let document else { return 0 }
        return PrintPagination.pages(
            for: document,
            geometry: geometry,
            compact: settings.fitsOnOnePage
        ).count
    }

    var body: some View {
        NavigationStack {
            Form {
                previewSection
                contentSection
                if settings.showsDayOptions { spanSection }
                paperSection
                if appState.showsNutritionEstimates, settings.showsDayOptions { nutritionSection }
                if settings.showsDayOptions { detailSection }
            }
            .formStyle(.grouped)
            .navigationTitle(String(localized: "Print plan"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Done")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Print…"), systemImage: "printer") { printNow() }
                        .disabled(document == nil || isRendering)
                }
                ToolbarItem(placement: .secondaryAction) {
                    Button(String(localized: "Save as PDF…"), systemImage: "doc.richtext") { savePDF() }
                        .disabled(document == nil || isRendering)
                }
            }
            .task(id: reloadKey) { rebuild() }
            .onAppear {
                if let initialContent, settings.content != initialContent {
                    settings.content = initialContent
                }
            }
            .onChange(of: settings) { _, updated in updated.save() }
            .sheet(item: $exportedPDF) { pdf in
                PDFShareSheet(url: pdf.url)
                    .dismissesOnOutsideClick()
            }
            .fileExporter(
                isPresented: $showingSavePanel,
                document: PlanPDFDocument(data: savedPDF ?? Data()),
                contentType: .pdf,
                defaultFilename: MealPlanPDFRenderer.filename(
                    for: range,
                    householdName: appState.currentHousehold?.name ?? "MealPlan"
                )
            ) { result in
                if case let .failure(error) = result { errorMessage = error.localizedDescription }
            }
            .alert(
                String(localized: "Couldn’t prepare the printout"),
                isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
            ) {
                Button(String(localized: "OK"), role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 620)
        #endif
    }

    /// Everything that changes what the printout says or how it is cut into
    /// sheets, in one value, so a change rebuilds the document exactly once.
    private var reloadKey: String {
        let nutrition = settings.nutrition
        return [
            range.start.dayID,
            range.end.dayID,
            settings.content.rawValue,
            settings.paper.rawValue,
            settings.orientation.rawValue,
            "\(nutrition.perMeal)\(nutrition.perDay)\(nutrition.summary)\(nutrition.macros)",
            "\(settings.showsNotes)\(settings.showsEmptyMeals)\(settings.fitsOnOnePage)",
        ].joined(separator: "|")
    }

    // MARK: - Sections

    @ViewBuilder
    private var previewSection: some View {
        Section {
            if let document,
               let first = PrintPagination.pages(
                   for: document,
                   geometry: geometry,
                   compact: settings.fitsOnOnePage
               ).first {
                PrintPagePreview(document: document, page: first, geometry: geometry)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        } footer: {
            Text(sheetSummary)
        }
    }

    private var sheetSummary: String {
        guard pageCount > 0 else { return "" }
        guard settings.showsDayOptions else {
            return String(localized: "\(pageCount) sheets of \(settings.paper.localizedName)")
        }
        let days = range.days.count
        return String(localized: "\(days) days on \(pageCount) sheets of \(settings.paper.localizedName)")
    }

    private var contentSection: some View {
        Section {
            Picker(String(localized: "Print"), selection: $settings.content) {
                ForEach(PrintContent.allCases) { content in
                    Text(content.localizedName).tag(content)
                }
            }
        } footer: {
            if settings.content.includesShoppingList {
                Text(String(
                    localized: "The shopping list prints as it stands, ticked items left out. Rebuild it on the Shopping screen first if it is out of date."
                ))
            }
        }
    }

    private var spanSection: some View {
        Section(String(localized: "Days")) {
            Picker(String(localized: "Time span"), selection: $settings.span) {
                ForEach(PrintSpan.allCases) { span in
                    Text(span.localizedName).tag(span)
                }
            }
            if settings.span == .custom {
                DatePicker(
                    String(localized: "From"),
                    selection: $customStart,
                    displayedComponents: .date
                )
                DatePicker(
                    String(localized: "To"),
                    selection: customEnd,
                    in: customStart...,
                    displayedComponents: .date
                )
            }
        }
    }

    /// The last day of a custom span, as a binding onto its length — the way a
    /// person thinks about it ("to the 30th"), stored the way it survives being
    /// reopened next month (a number of days).
    private var customEnd: Binding<Date> {
        Binding(
            get: { customStart.startOfDay.adding(days: max(0, settings.customDayCount - 1)) },
            set: { newValue in
                let days = Calendar.current.dateComponents(
                    [.day],
                    from: customStart.startOfDay,
                    to: newValue.startOfDay
                ).day ?? 0
                settings.customDayCount = MealPlanPrintSettings.clampedDayCount(days + 1)
            }
        )
    }

    private var paperSection: some View {
        Section(String(localized: "Paper")) {
            Picker(String(localized: "Size"), selection: $settings.paper) {
                ForEach(PaperSize.allCases) { paper in
                    Text("\(paper.localizedName) · \(paper.dimensionsText)").tag(paper)
                }
            }
            Picker(String(localized: "Orientation"), selection: $settings.orientation) {
                ForEach(PrintOrientation.allCases) { orientation in
                    Text(orientation.localizedName).tag(orientation)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private var nutritionSection: some View {
        Section {
            Toggle(String(localized: "Per meal"), isOn: $settings.nutrition.perMeal)
            Toggle(String(localized: "Per day"), isOn: $settings.nutrition.perDay)
            Toggle(String(localized: "Summary page"), isOn: $settings.nutrition.summary)
            Toggle(String(localized: "Protein, carbs and fat"), isOn: $settings.nutrition.macros)
                .disabled(!settings.nutrition.isAnythingOn)
        } header: {
            Text(String(localized: "Nutrition"))
        } footer: {
            Text(String(
                localized: "Estimates for one person, accurate to about ±20 %. Meals MealPlan can’t work out are left blank."
            ))
        }
    }

    private var detailSection: some View {
        Section {
            Toggle(String(localized: "Fit on one page"), isOn: $settings.fitsOnOnePage)
            Toggle(String(localized: "Meal notes"), isOn: $settings.showsNotes)
            Toggle(String(localized: "Empty meals"), isOn: $settings.showsEmptyMeals)
        } header: {
            Text(String(localized: "Details"))
        } footer: {
            Text(String(
                localized: "Fitting squeezes the days onto one sheet, in smaller type, as far as the columns can take it."
            ))
        }
    }

    // MARK: - Actions

    private func rebuild() {
        document = MealPlanPrintBuilder.document(
            range: range,
            settings: settings,
            householdName: appState.currentHousehold?.name ?? "MealPlan",
            energyUnit: appState.energyUnit,
            showsNutritionEstimates: appState.showsNutritionEstimates,
            context: context
        )
    }

    private func renderPDF() -> URL? {
        guard let document else { return nil }
        isRendering = true
        defer { isRendering = false }
        return MealPlanPDFRenderer.pdf(
            document: document,
            geometry: geometry,
            compact: settings.fitsOnOnePage,
            filename: MealPlanPDFRenderer.filename(
                for: range,
                householdName: appState.currentHousehold?.name ?? "MealPlan"
            )
        )
    }

    private func printNow() {
        guard let url = renderPDF() else {
            errorMessage = String(localized: "The plan couldn’t be rendered.")
            return
        }
        // No print panel to be had — hand the file over instead, which is
        // still a route to a printer on every platform.
        if !PlanPrinter.print(pdf: url, jobName: document?.title ?? "MealPlan") {
            exportedPDF = ExportedPDF(url: url)
        }
    }

    private func savePDF() {
        guard let url = renderPDF() else {
            errorMessage = String(localized: "The plan couldn’t be rendered.")
            return
        }
        #if os(macOS)
        guard let data = try? Data(contentsOf: url) else {
            errorMessage = String(localized: "The plan couldn’t be rendered.")
            return
        }
        savedPDF = data
        showingSavePanel = true
        #else
        exportedPDF = ExportedPDF(url: url)
        #endif
    }
}

/// The first sheet, shrunk to fit the dialog. Rendered from the same view the
/// PDF uses, so what is on screen is what comes out of the printer.
@MainActor
private struct PrintPagePreview: View {
    let document: MealPlanPrintDocument
    let page: PrintPage
    let geometry: PrintPageGeometry

    var body: some View {
        GeometryReader { proxy in
            let scale = min(
                proxy.size.width / geometry.size.width,
                proxy.size.height / geometry.size.height
            )
            MealPlanPrintPageView(
                document: document,
                page: page,
                geometry: geometry,
                // The sheet is drawn at about a third of its real size here, and
                // a 0.5 pt hairline shrunk that far lands under half a pixel:
                // the rasteriser keeps some and rounds others away, so the grid
                // looks like it is missing the lines between some of the days.
                // Thickening every rule by the factor the page is shrunk by puts
                // them all back at about a pixel. The printed sheet is
                // unaffected — it renders at strokeScale 1, true hairlines.
                strokeScale: min(4, max(1, 1 / scale))
            )
            // Scaled about its centre and then given the scaled size: with a
            // corner anchor the page keeps its full-size layout bounds and the
            // surrounding frame centres *those*, which pushes most of the sheet
            // outside the box.
            .scaleEffect(scale)
            .frame(width: geometry.size.width * scale, height: geometry.size.height * scale)
            .overlay { Rectangle().strokeBorder(.separator, lineWidth: 0.5) }
            .shadow(radius: 2, y: 1)
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .frame(height: 220)
        .accessibilityHidden(true)
    }
}

#Preview {
    PrintPlanSheet(referenceWeek: .now)
        .environment(AppState.preview)
        .modelContainer(PreviewData.container)
}
