import SwiftUI
import SwiftData

/// Reviews a recipe file before it lands in the library.
///
/// A 52-recipe Paprika export is far too much to accept blind, so the sheet
/// says up front what each recipe would do — arrive as new, join an existing
/// dish as a variant, or be skipped as something already there — and lets the
/// cook overrule any of it.
@MainActor
struct ImportRecipesSheet: View {
    let fileURL: URL

    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var phase: Phase = .loading
    @State private var plan: [PlannedRecipeImport] = []

    private enum Phase: Equatable { case loading, review, importing, failed(String) }

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .loading:
                    ProgressView(String(localized: "Reading recipes…"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .importing:
                    ProgressView(String(localized: "Importing…"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .failed(let message):
                    ContentUnavailableView(
                        String(localized: "Couldn’t read that file"),
                        systemImage: "exclamationmark.triangle",
                        description: Text(message)
                    )
                case .review:
                    reviewList
                }
            }
            .navigationTitle(String(localized: "Import recipes"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Import")) { runImport() }
                        .disabled(phase != .review || selectedCount == 0)
                }
            }
        }
        .task { await load() }
    }

    // MARK: - Review

    private var reviewList: some View {
        List {
            Section {
                LabeledContent(String(localized: "In this file"), value: "\(plan.count)")
                LabeledContent(String(localized: "Selected"), value: "\(selectedCount)")
                if alreadyKnownCount > 0 {
                    LabeledContent(String(localized: "Already in your library"), value: "\(alreadyKnownCount)")
                }
                if variantCount > 0 {
                    LabeledContent(String(localized: "New variants"), value: "\(variantCount)")
                }
            } footer: {
                Text("Recipes you already have are left out. Another take on a dish you already have comes in as a variant, so several burgers can live side by side.")
            }

            Section {
                ForEach($plan) { $item in
                    Toggle(isOn: $item.include) {
                        row(for: item)
                    }
                    .toggleStyle(.switch)
                }
            } header: {
                HStack {
                    Text(String(localized: "Recipes"))
                    Spacer()
                    Button(selectedCount == plan.count
                           ? String(localized: "Deselect all")
                           : String(localized: "Select all")) {
                        let selectAll = selectedCount < plan.count
                        for index in plan.indices { plan[index].include = selectAll }
                    }
                    .font(.caption)
                    .textCase(nil)
                }
            }
        }
    }

    private func row(for item: PlannedRecipeImport) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(item.recipe.name)
                .lineLimit(2)
            HStack(spacing: 6) {
                Image(systemName: symbol(for: item.outcome))
                Text(caption(for: item))
            }
            .font(.caption)
            .foregroundStyle(tint(for: item.outcome))
        }
    }

    private func caption(for item: PlannedRecipeImport) -> String {
        switch item.outcome {
        case .new:
            String(localized: "New — \(item.recipe.ingredientLines.count) ingredients")
        case .variant(let match):
            String(localized: "Variant of “\(match.name)”")
        case .duplicate(let match):
            String(localized: "Already saved as “\(match.name)”")
        case .duplicateInFile(let name):
            String(localized: "Listed twice in this file as “\(name)”")
        }
    }

    private func symbol(for outcome: RecipeImportOutcome) -> String {
        switch outcome {
        case .new: "plus.circle"
        case .variant: "square.on.square"
        case .duplicate, .duplicateInFile: "equal.circle"
        }
    }

    private func tint(for outcome: RecipeImportOutcome) -> Color {
        switch outcome {
        case .new: .green
        case .variant: .indigo
        case .duplicate, .duplicateInFile: .secondary
        }
    }

    private var selectedCount: Int {
        plan.filter(\.include).count
    }
    private var variantCount: Int {
        plan.filter { item in
            guard item.include, case .variant = item.outcome else { return false }
            return true
        }.count
    }
    private var alreadyKnownCount: Int {
        plan.filter { $0.outcome.isSkippedByDefault }.count
    }

    // MARK: - Work

    private func load() async {
        do {
            let recipes = try RecipeImportCommitter.recipes(fromFileAt: fileURL)
            guard !recipes.isEmpty else {
                phase = .failed(String(localized: "No recipes in that file."))
                return
            }
            let library = (try? context.fetch(FetchDescriptor<Dish>())) ?? []
            plan = RecipeImportPlanner.plan(recipes, against: library)
            phase = .review
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func runImport() {
        phase = .importing
        let result = RecipeImportCommitter.commit(
            plan,
            household: appState.currentHousehold,
            createdByName: appState.currentMemberName,
            context: context
        )
        SharedStore.reloadWidgets()
        appState.importNotice = result.summary
        dismiss()
    }
}
