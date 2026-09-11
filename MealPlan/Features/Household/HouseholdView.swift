import SwiftUI
import SwiftData

@MainActor
struct HouseholdSettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var context

    @State private var showingShareSheet = false
    @State private var showingJoinNearby = false
    @State private var memberPendingRemoval: HouseholdMember?
    @State private var removingMemberID: UUID?
    @State private var removalErrorMessage: String?

    /// People who currently have access. Someone removed from the share keeps
    /// an inactive row (see `HouseholdCloudSharingService.refreshMembers`) so
    /// plan attribution still has a name, but no longer counts as planning.
    private var members: [HouseholdMember] {
        (appState.currentHousehold?.members ?? []).filter(\.isActive).sorted { $0.dateAdded < $1.dateAdded }
    }

    /// Removing people is the owner's call, the same as inviting them — and
    /// unlike inviting, it needs a share to remove them from.
    private func canRemoveMembers(from household: Household) -> Bool {
        !appState.isGuest && HouseholdCloudSharingService.isOwner(shareIdentifier: household.cloudKitShareIdentifier) == true
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
                    Button {
                        showingJoinNearby = true
                    } label: {
                        Label("Join a Household Nearby", systemImage: "dot.radiowaves.left.and.right")
                    }
                } footer: {
                    Text("Someone who already plans with MealPlan can add you from their device while you’re together, no email address needed.")
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

                Section {
                    LabeledContent(String(localized: "You"), value: appState.currentMemberName)
                    ForEach(members) { member in
                        memberRow(member, removable: canRemoveMembers(from: household) && HouseholdCloudSharingService.canRemove(member))
                    }
                } header: {
                    Text("Who’s planning")
                } footer: {
                    if canRemoveMembers(from: household), members.contains(where: HouseholdCloudSharingService.canRemove) {
                        #if os(macOS)
                        Text("Control-click someone to remove them from the household.")
                        #else
                        Text("Swipe someone’s name to remove them from the household.")
                        #endif
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
        .navigationTitle(String(localized: "Household"))
        .sheet(isPresented: $showingShareSheet) {
            if let household = appState.currentHousehold {
                HouseholdSharingView(household: household)
                    .dismissesOnOutsideClick()
            }
        }
        .sheet(isPresented: $showingJoinNearby) {
            JoinNearbyHouseholdView(code: nil)
        }
        .confirmationDialog(
            String(localized: "Remove \(memberPendingRemoval?.name ?? "")?"),
            isPresented: Binding(get: { memberPendingRemoval != nil }, set: { if !$0 { memberPendingRemoval = nil } }),
            titleVisibility: .visible,
            presenting: memberPendingRemoval
        ) { member in
            Button(String(localized: "Remove from Household"), role: .destructive) {
                Task { await remove(member) }
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: { member in
            Text("\(member.name) will lose access to the shared plan and shopping list right away. They keep a copy of the household’s recipes.")
        }
        .alert(
            String(localized: "Couldn’t Remove"),
            isPresented: Binding(get: { removalErrorMessage != nil }, set: { if !$0 { removalErrorMessage = nil } }),
            presenting: removalErrorMessage
        ) { _ in
            Button(String(localized: "OK")) {}
        } message: { message in
            Text(message)
        }
    }

    private func memberRow(_ member: HouseholdMember, removable: Bool) -> some View {
        LabeledContent(member.name) {
            if removingMemberID == member.uuid {
                ProgressView()
                    .controlSize(.small)
            } else {
                Text(member.role.localizedName)
            }
        }
        .swipeActions {
            if removable {
                Button(role: .destructive) {
                    memberPendingRemoval = member
                } label: {
                    Label(String(localized: "Remove"), systemImage: "person.fill.xmark")
                }
            }
        }
        .contextMenu {
            if removable {
                Button(role: .destructive) {
                    memberPendingRemoval = member
                } label: {
                    Label(String(localized: "Remove from Household"), systemImage: "person.fill.xmark")
                }
            }
        }
    }

    private func remove(_ member: HouseholdMember) async {
        guard let household = appState.currentHousehold else { return }
        removingMemberID = member.uuid
        defer { removingMemberID = nil }
        do {
            try await HouseholdCloudSharingService.removeMember(member, from: household, context: context)
        } catch {
            removalErrorMessage = error.localizedDescription
        }
    }
}

#Preview {
    NavigationStack { HouseholdSettingsView() }
        .environment(AppState.preview)
        .modelContainer(PreviewData.container)
}
