import SwiftUI

/// Add a whole pasted list to the shopping list at once — one item per line,
/// each parsed for its amount the way a single typed item is.
@MainActor
struct ShoppingListPasteSheet: View {
    var onAdd: ([String]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    private var lines: [String] { ShoppingListPaste.lines(from: text) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $text)
                        .frame(minHeight: 180)
                        .accessibilityLabel(String(localized: "Items, one per line"))
                } footer: {
                    Text("One item per line, for example “500 g Mehl”. Bullets and checkboxes from a copied list are ignored.")
                }
                if !lines.isEmpty {
                    Section(String(localized: "Preview")) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                            Text(line)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(String(localized: "Add several items"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(lines.count == 1
                           ? String(localized: "Add 1 item")
                           : String(localized: "Add \(lines.count) items")) {
                        onAdd(lines)
                        dismiss()
                    }
                    .disabled(lines.isEmpty)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 420)
        #endif
    }
}
