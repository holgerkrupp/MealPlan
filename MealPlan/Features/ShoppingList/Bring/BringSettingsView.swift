import SwiftUI
import SwiftData

/// Connecting the family's shopping list to a list in Bring!.
///
/// The account is this device's — Bring! has no way for another app to be
/// authorized on your behalf, so signing in means giving MealPlan the account's
/// password, which goes to the keychain and to `api.getbring.com` and nowhere
/// else. Which list to use is the family's, so it syncs with the rest of the
/// household.
@MainActor
struct BringSettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var context

    private var service: BringSyncService { .shared }

    @State private var email = ""
    @State private var password = ""
    @State private var lists: [BringList] = []
    @State private var isWorking = false
    @State private var message: String?
    @State private var isSignedIn = BringSyncService.shared.hasAccount

    var body: some View {
        Form {
            if isSignedIn {
                accountSection
                listSection
                if appState.currentHousehold?.isConnectedToBring == true {
                    syncSection
                }
            } else {
                signInSection
            }

            Section {
                if let message {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("Bring! doesn’t offer apps a way to connect on your behalf, so MealPlan signs in the way the Bring! app does. If you created your Bring! account with Apple or Google, set a password in Bring! first. Bring! can change how this works at any time — when it stops working, your MealPlan list is untouched.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle(String(localized: "Bring!"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .disabled(isWorking)
        .task { await loadListsIfNeeded() }
    }

    // MARK: - Sections

    private var signInSection: some View {
        Section {
            TextField(String(localized: "Bring! email"), text: $email)
                .textContentType(.username)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.emailAddress)
                #endif
                .autocorrectionDisabled()
            SecureField(String(localized: "Bring! password"), text: $password)
                .textContentType(.password)
            Button {
                Task { await signIn() }
            } label: {
                Label(String(localized: "Connect to Bring!"), systemImage: "link")
            }
            .disabled(email.trimmingCharacters(in: .whitespaces).isEmpty || password.isEmpty)
        } header: {
            Text("Your Bring! account")
        } footer: {
            Text("Your shopping list can be sent to Bring! — or kept in step with it, so ticking something off in either app ticks it off in the other.")
        }
    }

    private var accountSection: some View {
        Section {
            LabeledContent(String(localized: "Signed in as"), value: service.accountEmail ?? "—")
            Button(role: .destructive) {
                service.signOut(household: appState.currentHousehold, context: context)
                isSignedIn = false
                lists = []
                password = ""
                message = String(localized: "Disconnected. Nothing was removed from either list.")
            } label: {
                Label(String(localized: "Disconnect"), systemImage: "minus.circle")
            }
        } header: {
            Text("Your Bring! account")
        }
    }

    @ViewBuilder
    private var listSection: some View {
        if let household = appState.currentHousehold {
            Section {
                if lists.isEmpty {
                    Button {
                        Task { await loadLists() }
                    } label: {
                        Label(String(localized: "Load my Bring! lists"), systemImage: "arrow.clockwise")
                    }
                }
                ForEach(lists) { list in
                    Button {
                        service.use(list, household: household, context: context)
                    } label: {
                        HStack {
                            Text(list.name)
                                .foregroundStyle(.primary)
                            Spacer()
                            if household.bringListUuid == list.listUuid {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("Which list")
            } footer: {
                Text("Pick the Bring! list this family’s shopping list belongs to. Everyone in your family who connects their own Bring! account should pick the same one.")
            }
        }
    }

    @ViewBuilder
    private var syncSection: some View {
        if let household = appState.currentHousehold {
            Section {
                Toggle(String(localized: "Keep both lists in step"), isOn: Binding(
                    get: { household.bringAutoSync },
                    set: { household.bringAutoSync = $0; try? context.save() }
                ))
                Button {
                    Task { await perform { try await service.sync(household: household, context: context) } }
                } label: {
                    Label(String(localized: "Sync now"), systemImage: "arrow.triangle.2.circlepath")
                }
                Button {
                    Task { await perform { try await service.push(household: household, context: context) } }
                } label: {
                    Label(String(localized: "Send the whole list to Bring!"), systemImage: "arrow.up.doc")
                }
                if let synced = household.bringLastSyncedAt {
                    LabeledContent(
                        String(localized: "Last synced"),
                        value: synced.formatted(date: .abbreviated, time: .shortened)
                    )
                }
            } header: {
                Text("Syncing")
            } footer: {
                Text("In step means both ways: what the plan puts on your list appears in Bring!, what somebody adds in Bring! appears here, and ticking something off in either app takes it off the other. Amounts come from your meal plan, so a rebuild rewrites them in Bring! too.")
            }
        }
    }

    // MARK: - Actions

    private func signIn() async {
        await perform {
            let found = try await service.signIn(
                email: email.trimmingCharacters(in: .whitespacesAndNewlines),
                password: password
            )
            lists = found
            isSignedIn = true
            password = ""
            if let household = appState.currentHousehold,
               household.bringListUuid == nil,
               found.count == 1 {
                // One list is not a choice worth making anyone make.
                service.use(found[0], household: household, context: context)
            }
            return nil
        }
    }

    private func loadListsIfNeeded() async {
        guard isSignedIn, lists.isEmpty else { return }
        await loadLists()
    }

    private func loadLists() async {
        await perform {
            lists = try await service.lists()
            return nil
        }
    }

    /// Every call to Bring! looks the same from here: block the form, run it,
    /// and say in one line what happened — including when it didn't work.
    private func perform(_ work: () async throws -> BringSyncService.Outcome?) async {
        isWorking = true
        message = nil
        do {
            if let outcome = try await work() {
                message = outcome.summary
            }
        } catch {
            message = error.localizedDescription
        }
        isWorking = false
    }
}

#Preview {
    NavigationStack { BringSettingsView() }
        .environment(AppState.preview)
        .modelContainer(PreviewData.container)
}
