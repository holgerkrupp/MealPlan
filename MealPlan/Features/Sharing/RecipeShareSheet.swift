import SwiftUI
import SwiftData
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Every way a recipe can leave the app, on one sheet.
///
/// * **MealPlan recipe** — the `.mealplanrecipes` archive, for someone who has
///   the app but isn't in this household. AirDropped to an iPhone, iPad or Mac
///   it opens straight in their MealPlan, photos and all, and goes through the
///   same import (and duplicate check) as any recipe file.
/// * **PDF** — a formatted cookbook page, for anyone.
/// * **Text** — ingredients and method as a message.
/// * **Original recipe** — the page it came from, once it's been checked to
///   still be there.
///
/// The PDF and the text use whatever the recipe was showing when the sheet
/// opened — the same number of servings, the same language — with the
/// servings adjustable here.
@MainActor
struct RecipeShareSheet: View {
    let dish: Dish
    let translated: Bool

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var servings: Int
    @State private var archiveURL: URL?
    @State private var archiveError: String?
    @State private var pdfURL: URL?
    @State private var pdfError: String?
    @State private var previewImage: Image?
    @State private var linkStatus: RecipeSourceLink.Availability = .checking
    @State private var copiedText = false
    #if os(macOS)
    @State private var savingPDF = false
    #endif

    init(dish: Dish, servings: Int, translated: Bool) {
        self.dish = dish
        self.translated = translated
        _servings = State(initialValue: max(1, servings))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    recipeHeader
                }

                Section {
                    archiveRow
                } header: {
                    Text("Someone with MealPlan")
                } footer: {
                    Text("Sends the whole recipe with its photos, ingredients and tags. AirDrop it to a nearby iPhone, iPad or Mac and it opens straight in their MealPlan — they don’t need to be in your household.")
                }

                Section {
                    pdfRow
                    textRow
                } header: {
                    Text("Anyone")
                } footer: {
                    Text("Amounts are for \(servings) servings.")
                }

                Section {
                    NavigationLink {
                        RecipeImageShareView(dish: dish, content: content)
                    } label: {
                        formatLabel(
                            String(localized: "Images"),
                            String(localized: "For Instagram, Mastodon, Pixelfed and the like"),
                            systemImage: "photo.on.rectangle.angled"
                        )
                    }
                } header: {
                    Text("Social media")
                }

                if content.hasWebSource {
                    Section {
                        sourceRow
                    } header: {
                        Text("Original recipe")
                    } footer: {
                        if let note = sourceFootnote {
                            Text(note)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(String(localized: "Share recipe"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Done")) { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, idealWidth: 500, minHeight: 560)
        .fileExporter(
            isPresented: $savingPDF,
            document: pdfURL.flatMap { try? Data(contentsOf: $0) }.map(PlanPDFDocument.init(data:)),
            contentType: .pdf,
            defaultFilename: pdfURL?.deletingPathExtension().lastPathComponent
        ) { _ in }
        #endif
        .task { await prepareArchive() }
        .task(id: PDFInputs(servings: servings, sourceIsGone: linkStatus == .gone)) { await preparePDF() }
        .task { await checkSource() }
    }

    // MARK: - Content

    /// Rebuilt as the servings change; cheap without the photo, which only the
    /// PDF needs.
    private var content: RecipeShareContent {
        var content = RecipeShareContent.make(
            dish: dish,
            servings: servings,
            translated: translated,
            system: appState.unitSystem,
            roundsAmounts: appState.roundsDisplayedAmounts,
            energyUnit: appState.showsNutritionEstimates ? appState.energyUnit : nil,
            includesImage: false
        )
        content.sourceIsGone = linkStatus == .gone
        return content
    }

    private struct PDFInputs: Equatable {
        var servings: Int
        var sourceIsGone: Bool
    }

    // MARK: - Rows

    private var recipeHeader: some View {
        HStack(spacing: 12) {
            DishThumbnail(dish: dish, size: 48, cornerRadius: 10)
            VStack(alignment: .leading, spacing: 6) {
                Text(content.title)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                Stepper(value: $servings, in: 1...50) {
                    Text("\(servings) servings")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var archiveRow: some View {
        if let archiveURL {
            ShareLink(item: archiveURL, preview: preview) {
                formatLabel(
                    String(localized: "MealPlan recipe"),
                    String(localized: "AirDrop, Messages or Mail"),
                    systemImage: "fork.knife.circle"
                )
            }
        } else {
            pendingRow(
                String(localized: "MealPlan recipe"),
                systemImage: "fork.knife.circle",
                error: archiveError
            )
        }
    }

    @ViewBuilder
    private var pdfRow: some View {
        if let pdfURL {
            HStack {
                ShareLink(item: pdfURL, preview: preview) {
                    formatLabel(
                        String(localized: "PDF"),
                        String(localized: "A formatted recipe page, ready to print"),
                        systemImage: "doc.richtext"
                    )
                }
                .buttonStyle(.borderless)
                #if os(macOS)
                Button(String(localized: "Save PDF…"), systemImage: "square.and.arrow.down") {
                    savingPDF = true
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help(String(localized: "Save PDF…"))
                #endif
                Button(String(localized: "Print…"), systemImage: "printer") {
                    PlanPrinter.print(pdf: pdfURL, jobName: content.title)
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help(String(localized: "Print…"))
            }
        } else {
            pendingRow(String(localized: "PDF"), systemImage: "doc.richtext", error: pdfError)
        }
    }

    private var textRow: some View {
        HStack {
            ShareLink(
                item: content.plainText,
                subject: Text(content.title),
                preview: SharePreview(content.title)
            ) {
                formatLabel(
                    String(localized: "Text"),
                    String(localized: "Ingredients and method as a message"),
                    systemImage: "text.alignleft"
                )
            }
            .buttonStyle(.borderless)
            Button(
                copiedText ? String(localized: "Copied") : String(localized: "Copy text"),
                systemImage: copiedText ? "checkmark" : "doc.on.doc"
            ) {
                copyText()
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help(String(localized: "Copy text"))
        }
    }

    @ViewBuilder
    private var sourceRow: some View {
        let host = content.sourceHost ?? String(localized: "Website")
        switch linkStatus {
        case .checking:
            HStack {
                formatLabel(host, String(localized: "Checking the page is still online…"), systemImage: "safari")
                Spacer()
                ProgressView().controlSize(.small)
            }
        case .available, .unknown:
            if let url = dish.sourceURL {
                ShareLink(item: url) {
                    formatLabel(host, String(localized: "Link to the page this recipe came from"), systemImage: "safari")
                }
            }
        case .gone:
            formatLabel(host, String(localized: "This page is no longer available"), systemImage: "link.badge.plus")
                .foregroundStyle(.secondary)
                .symbolRenderingMode(.hierarchical)
        }
    }

    private var sourceFootnote: String? {
        switch linkStatus {
        case .unknown: String(localized: "Couldn’t check whether the page is still online.")
        case .gone: String(localized: "The PDF and text still credit the site, without the dead link.")
        case .checking, .available: nil
        }
    }

    private func formatLabel(_ title: String, _ subtitle: String, systemImage: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: systemImage)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func pendingRow(_ title: String, systemImage: String, error: String?) -> some View {
        HStack {
            formatLabel(
                title,
                error ?? String(localized: "Preparing…"),
                systemImage: error == nil ? systemImage : "exclamationmark.triangle"
            )
            if error == nil {
                Spacer()
                ProgressView().controlSize(.small)
            }
        }
        .foregroundStyle(.secondary)
    }

    private var preview: SharePreview<Image, Never> {
        SharePreview(content.title, image: previewImage ?? Image(systemName: "fork.knife"))
    }

    // MARK: - Work

    private func prepareArchive() async {
        if let data = dish.primaryImageData {
            previewImage = Image(data: ImagePreparation.prepared(from: data, maxDimension: 400, quality: 0.7))
        }
        do {
            archiveURL = try MealPlanRecipeArchive.temporaryFile(for: [dish])
        } catch {
            archiveError = error.localizedDescription
        }
    }

    private func preparePDF() async {
        // Let a run of stepper taps settle before laying the pages out again.
        if pdfURL != nil {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
        }
        var content = RecipeShareContent.make(
            dish: dish,
            servings: servings,
            translated: translated,
            system: appState.unitSystem,
            roundsAmounts: appState.roundsDisplayedAmounts,
            energyUnit: appState.showsNutritionEstimates ? appState.energyUnit : nil
        )
        content.sourceIsGone = linkStatus == .gone
        do {
            pdfURL = try RecipePDFRenderer.pdf(content: content, geometry: RecipePDFRenderer.defaultGeometry)
            pdfError = nil
        } catch {
            pdfError = error.localizedDescription
        }
    }

    private func checkSource() async {
        guard content.hasWebSource, let url = dish.sourceURL else { return }
        linkStatus = await RecipeSourceLink.check(url)
    }

    private func copyText() {
        let text = content.plainText
        #if os(iOS)
        UIPasteboard.general.string = text
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
        copiedText = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copiedText = false
        }
    }
}

#Preview {
    RecipeShareSheet(
        dish: PreviewData.household.dishes?.first(where: { $0.name.contains("Pfann") }) ?? Dish(name: "Test"),
        servings: 4,
        translated: false
    )
    .environment(AppState.preview)
    .modelContainer(PreviewData.container)
}
