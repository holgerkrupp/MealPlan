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

    /// Only the owner can invite further participants: a household that's
    /// already shared and whose share this device didn't create is one this
    /// device joined as an editor, not the owner.
    private func canInvite(_ household: Household) -> Bool {
        HouseholdCloudSharingService.isOwner(shareIdentifier: household.cloudKitShareIdentifier) ?? true
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
