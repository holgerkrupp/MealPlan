import SwiftUI
import SwiftData

@MainActor
struct HouseholdSettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var context

    @State private var showingShareSheet = false
    @State private var isConfirmingLegacyRecovery = false
    @State private var isReconcilingLegacyHouseholds = false
    @State private var legacyRecoveryErrorMessage: String?

    /// People who currently have access. Inactive rows remain for attribution.
    private var members: [HouseholdMember] {
        (appState.currentHousehold?.members ?? []).filter(\.isActive).sorted { $0.dateAdded < $1.dateAdded }
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

                if case .reviewRequired = appState.legacyHouseholdRecovery {
                    Section {
                        Label("Another household needs review", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                        Button {
                            isConfirmingLegacyRecovery = true
                        } label: {
                            if isReconcilingLegacyHouseholds {
                                HStack {
                                    ProgressView()
                                    Text("Copying household data…")
                                }
                            } else {
                                Label("Review and Copy Household Data", systemImage: "arrow.triangle.merge")
                            }
                        }
                        .disabled(isReconcilingLegacyHouseholds)
                    } footer: {
                        Text("MealPlan found more than one populated household for this Apple Account. Copying moves this device to the active shared household and retains every original iCloud zone as a backup.")
                    }
                }

                Section {
                    NavigationLink {
                        HouseholdRecoveryView()
                    } label: {
                        Label(String(localized: "Household Recovery"), systemImage: "arrow.triangle.2.circlepath.icloud")
                    }
                } footer: {
                    Text("Choose an exact iCloud household to restore on this device, safely reset this device, or recover an owner household moved to Recently Deleted.")
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

                    NavigationLink {
                        IngredientCleanupView()
                    } label: {
                        LabeledContent {
                            Text(ingredientCleanupSummary(household))
                        } label: {
                            Label(String(localized: "Ingredient Cleanup"), systemImage: "wand.and.stars")
                        }
                    }
                } footer: {
                    Text("Salt, pepper, oil — what your family always has at home. Staples stay off the shopping list when it's rebuilt, and you can put one on it yourself when you run out.")
                }

                Section {
                    NavigationLink {
                        FoodProfilesView(members: members)
                    } label: {
                        Label("Food profiles", systemImage: "fork.knife.circle")
                    }
                } footer: {
                    Text("Optional preferences help MealPlan filter and rank recipes. Nothing is inferred, and every profile can be removed.")
                }

                Section {
                    LabeledContent(String(localized: "You"), value: appState.currentMemberName)
                    ForEach(members) { member in
                        LabeledContent(member.name, value: member.role.localizedName)
                    }
                } header: {
                    Text("Who’s planning")
                }

                #if DEBUG
                Section {
                    NavigationLink {
                        LegacyHouseholdDiagnosticsView()
                    } label: {
                        Label("Collaboration Diagnostics", systemImage: "ladybug")
                    }
                } footer: {
                    Text("Shows identifiers, scopes, pending counts and errors only; no recipe or member data.")
                }
                #endif
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
        .confirmationDialog(
            String(localized: "Copy household data into the canonical household?"),
            isPresented: $isConfirmingLegacyRecovery,
            titleVisibility: .visible
        ) {
            Button(String(localized: "Copy and Switch Household")) {
                Task { await reconcileLegacyHouseholds() }
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text("MealPlan will use the already shared household when one exists, then copy recipes, plans, shopping items and other unmatched data from the other household zones. It will not delete any CloudKit zone. If two records have the same identity, this device’s version is kept so you can review it later.")
        }
        .alert(
            String(localized: "Couldn’t Reconcile Households"),
            isPresented: Binding(get: { legacyRecoveryErrorMessage != nil }, set: { if !$0 { legacyRecoveryErrorMessage = nil } }),
            presenting: legacyRecoveryErrorMessage
        ) { _ in
            Button(String(localized: "OK")) {}
        } message: { message in
            Text(message)
        }
    }

    private func reconcileLegacyHouseholds() async {
        isReconcilingLegacyHouseholds = true
        defer { isReconcilingLegacyHouseholds = false }
        do {
            try await appState.reconcileLegacyHouseholds(context: context)
        } catch {
            legacyRecoveryErrorMessage = error.localizedDescription
        }
    }

    private func ingredientCleanupSummary(_ household: Household) -> String {
        let count = IngredientCleanupService.suggestions(in: household).count
        return count == 0 ? String(localized: "All clear") : String(localized: "(count) to review")
    }

}

@MainActor
private struct FoodProfilesView: View {
    var members: [HouseholdMember]

    var body: some View {
        List(members) { member in
            NavigationLink {
                FoodProfileEditor(member: member)
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(member.name)
                    let count = member.allergies.count + member.mustAvoidIngredients.count + member.dislikes.count + member.favorites.count
                    Text(count == 0 ? String(localized: "No preferences") : String(localized: "\(count) preferences"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Food profiles")
    }
}

@MainActor
private struct FoodProfileEditor: View {
    @Bindable var member: HouseholdMember
    @Environment(\.modelContext) private var context

    var body: some View {
        Form {
            Section {
                TextField("Allergies (comma separated)", text: arrayBinding(\.allergies))
                TextField("Must avoid (comma separated)", text: arrayBinding(\.mustAvoidIngredients))
            } header: {
                Text("Hard exclusions")
            } footer: {
                Text("Recipes containing these terms are filtered out for this person.")
            }

            Section {
                TextField("Dislikes (comma separated)", text: arrayBinding(\.dislikes))
                TextField("Favorites (comma separated)", text: arrayBinding(\.favorites))
                TextField("Preferred cuisines (comma separated)", text: arrayBinding(\.preferredCuisines))
                TextField("Dietary patterns (comma separated)", text: arrayBinding(\.dietaryPatterns))
            } header: {
                Text("Preferences")
            }
        }
        .formStyle(.grouped)
        .navigationTitle(member.name)
    }

    private func arrayBinding(_ keyPath: ReferenceWritableKeyPath<HouseholdMember, [String]>) -> Binding<String> {
        Binding(
            get: { member[keyPath: keyPath].joined(separator: ", ") },
            set: {
                member[keyPath: keyPath] = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                member.markProfileModified()
                try? context.save()
            }
        )
    }
}

#Preview {
    NavigationStack { HouseholdSettingsView() }
        .environment(AppState.preview)
        .modelContainer(PreviewData.container)
}
