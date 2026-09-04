import SwiftUI
import SwiftData

@MainActor
struct HouseholdView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var context

    @State private var showingShareSheet = false

    private var members: [HouseholdMember] {
        (appState.currentHousehold?.members ?? []).sorted { $0.dateAdded < $1.dateAdded }
    }

    /// How many things the family counts as always in stock, for the row that
    /// leads to them.
    private func staplesSummary(_ household: Household) -> String {
        let count = household.pantryStaples.count
        return count == 0 ? String(localized: "None") : "\(count)"
    }

    /// Only the owner can invite further participants: a household that's
    /// already shared and whose share this device didn't create is one this
    /// device joined as an editor, not the owner.
    private func canInvite(_ household: Household) -> Bool {
        HouseholdCloudSharingService.isOwner(shareIdentifier: household.cloudKitShareIdentifier) ?? true
    }

    /// Writes straight through to the household so the new standard reaches
    /// the rest of the family with the next iCloud sync.
    private func standardServings(_ household: Household) -> Binding<Int> {
        Binding(
            get: { household.scalingServings },
            set: { household.standardServings = max(1, $0); try? context.save() }
        )
    }

    var body: some View {
        Form {
            if let household = appState.currentHousehold {
                Section {
                    TextField(
                        String(localized: "Family name"),
                        text: Binding(
                            get: { household.name },
                            set: { household.name = $0; try? context.save() }
                        )
                    )
                    .font(.headline)
                    .disabled(appState.isGuest)
                } header: {
                    Text("This family")
                } footer: {
                    if appState.isGuest {
                        Label(String(localized: "You joined as a view-only guest."), systemImage: "eye")
                    }
                }

                Section {
                    Stepper(value: standardServings(household), in: 1...50) {
                        LabeledContent(
                            String(localized: "Standard portions"),
                            value: String(localized: "\(household.scalingServings) servings")
                        )
                    }
                    .disabled(appState.isGuest)
                } header: {
                    Text("How much you cook")
                } footer: {
                    Text("Recipes are scaled to this many portions automatically, whatever yield they were written for. You can still change the portions of a single meal when you plan it. This is shared with everyone in the family.")
                }

                if !appState.isGuest, canInvite(household) {
                    Section {
                        Button {
                            showingShareSheet = true
                        } label: {
                            Label("Share with family", systemImage: "person.crop.circle.badge.plus")
                        }
                    } footer: {
                        Text("Everyone you invite sees the same plan and dishes. You can invite people as editors or view-only guests.")
                    }
                }

                Section {
                    NavigationLink {
                        MealRoutinesView()
                    } label: {
                        Label(String(localized: "Regular meals"), systemImage: "repeat")
                    }
                } footer: {
                    Text("Standing arrangements like Taco Tuesday or pizza every second Sunday, planned into the calendar for you.")
                }

                Section {
                    NavigationLink {
                        PantryStaplesView()
                    } label: {
                        LabeledContent {
                            Text(staplesSummary(household))
                        } label: {
                            Label(String(localized: "Pantry staples"), systemImage: "shippingbox")
                        }
                    }
                } footer: {
                    Text("Salt, pepper, oil — what your family always has at home. Staples stay off the shopping list when it's rebuilt, and you can put one on it yourself when you run out.")
                }

                Section(String(localized: "Who’s planning")) {
                    LabeledContent(String(localized: "You"), value: appState.currentMemberName)
                    ForEach(members) { member in
                        LabeledContent(member.name, value: member.role.localizedName)
                    }
                }
            } else {
                ContentUnavailableView(
                    String(localized: "Setting up…"),
                    systemImage: "house",
                    description: Text("Your family is being created.")
                )
            }
        }
        .formStyle(.grouped)
        .navigationTitle(AppSection.household.title)
        .sheet(isPresented: $showingShareSheet) {
            if let household = appState.currentHousehold {
                HouseholdSharingView(household: household)
            }
        }
    }
}

#Preview {
    NavigationStack { HouseholdView() }
        .environment(AppState.preview)
        .modelContainer(PreviewData.container)
}
