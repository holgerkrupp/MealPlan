import SwiftUI
import SwiftData

/// Navigation value for a variant group. Carries the name so the destination
/// still has a title while its members are being fetched.
struct DishVariantGroupRef: Hashable, Identifiable {
    var id: UUID
    var name: String
}

/// The members of one variant group — three burgers, two bolognese — each
/// still a dish in its own right.
@MainActor
struct DishVariantGroupView: View {
    let group: DishVariantGroupRef

    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif
    @Query(sort: \Dish.name) private var allDishes: [Dish]

    @State private var renaming = false
    @State private var draftName = ""

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 240), spacing: 16)]

    private var members: [Dish] {
        DishVariants.sorted(allDishes.filter { $0.variantGroupID == group.id })
    }

    private var title: String {
        members.first?.variantGroupDisplayName ?? group.name
    }

    var body: some View {
        ScrollView {
            if members.isEmpty {
                ContentUnavailableView(
                    String(localized: "No variants left"),
                    systemImage: "square.on.square.dashed",
                    description: Text("Every recipe in this group has been removed from it.")
                )
                .frame(maxWidth: .infinity, minHeight: 320)
            } else {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(members) { dish in
                        #if os(macOS)
                        DishGridCell(dish: dish)
                            .onTapGesture {
                                openWindow(value: MacDetailWindowRoute.recipe(dish.uuid))
                            }
                            .accessibilityAddTraits(.isButton)
                            .accessibilityAction {
                                openWindow(value: MacDetailWindowRoute.recipe(dish.uuid))
                            }
                            .draggable(DishReference(dishUUID: dish.uuid, name: dish.name))
                            .contextMenu {
                                Button(String(localized: "Remove from group"), systemImage: "minus.circle") {
                                    removeFromGroup(dish)
                                }
                            }
                        #else
                        NavigationLink(value: dish) {
                            DishGridCell(dish: dish)
                        }
                        .buttonStyle(.plain)
                        .draggable(DishReference(dishUUID: dish.uuid, name: dish.name))
                        .contextMenu {
                            Button(String(localized: "Remove from group"), systemImage: "minus.circle") {
                                removeFromGroup(dish)
                            }
                        }
                        #endif
                    }
                }
                .padding()
            }
        }
        .navigationTitle(title)
        // Removing the last two members dissolves the group, and there is
        // nothing left on this screen to look at.
        .onChange(of: members.isEmpty) { _, isEmpty in
            if isEmpty { dismiss() }
        }
        .toolbar {
            if !appState.isGuest {
                ToolbarItem(placement: .primaryAction) {
                    Button(String(localized: "Rename group"), systemImage: "pencil") {
                        draftName = title
                        renaming = true
                    }
                    .disabled(members.isEmpty)
                }
            }
        }
        .alert(String(localized: "Rename group"), isPresented: $renaming) {
            TextField(String(localized: "Group name"), text: $draftName)
            Button(String(localized: "Save")) {
                guard let anyMember = members.first else { return }
                DishVariants.rename(groupOf: anyMember, to: draftName, in: allDishes)
                try? context.save()
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text("All \(members.count) recipes in this group are shown under this name.")
        }
    }

    private func removeFromGroup(_ dish: Dish) {
        DishVariants.leaveGroup(dish, in: allDishes)
        try? context.save()
    }
}

#Preview {
    NavigationStack {
        DishVariantGroupView(group: PreviewData.variantGroup)
    }
    .environment(AppState.preview)
    .modelContainer(PreviewData.container)
}
