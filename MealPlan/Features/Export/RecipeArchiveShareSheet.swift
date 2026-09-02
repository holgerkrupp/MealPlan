import SwiftUI

struct ExportedRecipeArchive: Identifiable {
    let id = UUID()
    let url: URL
}

struct RecipeArchiveShareSheet: View {
    let archive: ExportedRecipeArchive
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Image(systemName: "books.vertical")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                Text(String(localized: "Your portable recipe archive is ready."))
                    .multilineTextAlignment(.center)
                ShareLink(item: archive.url) {
                    Label(String(localized: "Share / Save"), systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
            .navigationTitle(String(localized: "Recipe archive"))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Done")) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

#Preview {
    RecipeArchiveShareSheet(
        archive: ExportedRecipeArchive(url: URL(fileURLWithPath: "/tmp/Rezepte.mealplanrecipes"))
    )
}
