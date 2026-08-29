import SwiftUI
import SwiftData

@MainActor
struct PantryStaplesView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Ingredient.name) private var ingredients: [Ingredient]
    @State private var searchText = ""

    private var filtered: [Ingredient] {
        guard !searchText.isEmpty else { return ingredients }
        return ingredients.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        List {
            Section {
                ForEach(filtered) { ingredient in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(ingredient.name)
                            Text(ingredient.aisleName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { ingredient.isPantryStaple },
                            set: { ingredient.isPantryStaple = $0; try? context.save() }
                        ))
                        .labelsHidden()
                    }
                }
            } footer: {
                Text("Staples are omitted when a shopping list is rebuilt. You can still add them manually whenever you run out.")
            }
        }
        .searchable(text: $searchText, prompt: String(localized: "Search ingredients"))
        .navigationTitle(String(localized: "Pantry staples"))
    }
}
