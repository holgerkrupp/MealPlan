import SwiftUI
import SwiftData
#if canImport(UIKit)
import CloudKit
#endif

@MainActor
struct HouseholdView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var context

    @State private var showingShareSheet = false
    @State private var shareError: String?

    private var members: [HouseholdMember] {
        (appState.currentHousehold?.members ?? []).sorted { $0.dateAdded < $1.dateAdded }
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

                if !appState.isGuest {
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
        #if canImport(UIKit)
        .sheet(isPresented: $showingShareSheet) {
            if let household = appState.currentHousehold {
                CloudSharingView(
                    householdName: household.name,
                    householdUUID: household.uuid,
                    onError: { shareError = $0.localizedDescription },
                    onShareSaved: { participants in
                        syncMembers(participants, into: household)
                    }
                )
                .ignoresSafeArea()
            }
        }
        #endif
        .alert(
            String(localized: "Couldn’t start sharing"),
            isPresented: Binding(get: { shareError != nil }, set: { if !$0 { shareError = nil } })
        ) {
            Button(String(localized: "OK"), role: .cancel) {}
        } message: {
            Text(shareError ?? "")
        }
    }

    #if canImport(UIKit)
    private func syncMembers(_ participants: [CKShare.Participant], into household: Household) {
        for existing in household.members ?? [] { context.delete(existing) }
        for participant in participants {
            let name = participant.userIdentity.nameComponents
                .map { PersonNameComponentsFormatter().string(from: $0) }
                .flatMap { $0.isEmpty ? nil : $0 }
                ?? String(localized: "Family member")
            let role: MemberRole = participant.role == .owner
                ? .owner
                : (participant.permission == .readOnly ? .guest : .editor)
            let member = HouseholdMember(name: name, role: role, isCurrentUser: participant.role == .owner)
            member.household = household
            context.insert(member)
        }
        try? context.save()
    }
    #endif
}

#Preview {
    NavigationStack { HouseholdView() }
        .environment(AppState.preview)
        .modelContainer(PreviewData.container)
}
