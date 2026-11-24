import SwiftUI
import SwiftData

/// The Plan section. On portrait phones and very narrow windows it is just the
/// calendar; everywhere else (iPad, Mac, phone in landscape) the calendar
/// keeps the leading side and a searchable dish list sits on the trailing
/// side, so dishes can be dragged straight onto a meal card. The divider
/// between them is draggable and the width is remembered.
@MainActor
struct PlanView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.horizontalSizeClass) private var sizeClass

    @AppStorage("plan.showsDishSidebar") private var showsSidebar = true
    @AppStorage("plan.dishSidebarWidth") private var sidebarWidth: Double = 300
    @State private var dragStartWidth: Double?
    @State private var showingMenus = false

    var body: some View {
        GeometryReader { geometry in
            let fits = PlanLayoutPolicy.supportsDishSidebar(
                in: geometry.size,
                horizontalSizeClass: sizeClass
            )
            let width = PlanLayoutPolicy.sidebarWidth(
                preferred: sidebarWidth,
                availableWidth: geometry.size.width
            )

            HStack(spacing: 0) {
                CalendarHomeView()
                    .frame(maxWidth: .infinity)

                if fits && showsSidebar {
                    resizeHandle(currentWidth: width, availableWidth: geometry.size.width)
                    DishSidebarView(householdID: appState.currentHousehold?.uuid)
                        .frame(width: width)
                        .transition(.move(edge: .trailing))
                }
            }
            // Nil while the window is too narrow to split, so the View menu's
            // toggle greys out instead of silently doing nothing.
            .focusedSceneValue(
                \.planSidebarCommands,
                fits
                    ? PlanSidebarCommands(
                        isShown: showsSidebar,
                        toggle: { withAnimation(.snappy) { showsSidebar.toggle() } }
                    )
                    : nil
            )
            .toolbar {
                if fits {
                    ToolbarItem(placement: .secondaryAction) {
                        Button {
                            withAnimation(.snappy) { showsSidebar.toggle() }
                        } label: {
                            Label(
                                showsSidebar
                                    ? String(localized: "Hide dish list")
                                    : String(localized: "Show dish list"),
                                systemImage: showsSidebar ? "sidebar.trailing" : "sidebar.leading"
                            )
                        }
                    }
                }
                ToolbarItem(placement: .secondaryAction) {
                    Button {
                        showingMenus = true
                    } label: {
                        Label(String(localized: "Menus"), systemImage: "rectangle.3.group")
                    }
                    .disabled(appState.currentHousehold == nil)
                }
            }
            .sheet(isPresented: $showingMenus) {
                ReusableMenuLibraryView()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func resizeHandle(currentWidth: Double, availableWidth: Double) -> some View {
        Divider()
            .frame(width: 10)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let start = dragStartWidth ?? currentWidth
                        if dragStartWidth == nil { dragStartWidth = start }
                        sidebarWidth = min(
                            max(start - Double(value.translation.width), PlanLayoutPolicy.minimumSidebarWidth),
                            PlanLayoutPolicy.maximumSidebarWidth(availableWidth: availableWidth)
                        )
                    }
                    .onEnded { _ in dragStartWidth = nil }
            )
            #if os(macOS)
            .pointerStyle(.columnResize)
            #endif
            .help(String(localized: "Drag to resize the dish list"))
            .accessibilityLabel(String(localized: "Resize dish list"))
    }
}

@MainActor
private struct ReusableMenuLibraryView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        NavigationStack {
            List {
                if let household = appState.currentHousehold {
                    if household.reusableMenus.isEmpty {
                        ContentUnavailableView(
                            String(localized: "No menus yet"),
                            systemImage: "rectangle.3.group",
                            description: Text("Save a few dishes together for a quick planning shortcut.")
                        )
                    } else {
                        ForEach(household.reusableMenus) { menu in
                            VStack(alignment: .leading) {
                                Text(menu.name)
                                Text(String(localized: "\(menu.items.count) dishes"))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .onDelete { offsets in
                            for index in offsets {
                                ReusableMenuStore.delete(household.reusableMenus[index].id, from: household)
                            }
                        }
                    }
                    Section(String(localized: "New menu")) {
                        TextField(String(localized: "Menu name"), text: $name)
                        Button(String(localized: "Create empty menu")) {
                            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !trimmed.isEmpty else { return }
                            ReusableMenuStore.save(ReusableMenu(name: trimmed), in: household)
                            name = ""
                        }
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .navigationTitle(String(localized: "Reusable menus"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Done")) { dismiss() }
                }
            }
        }
    }
}

/// Geometry rules for the plan's optional dish list. iPhones report a compact
/// horizontal size class in both orientations, so size class alone cannot
/// distinguish a narrow portrait plan from a landscape plan with room for two
/// useful columns.
enum PlanLayoutPolicy {
    static let minimumSidebarWidth: Double = 220
    static let maximumSidebarWidth: Double = 460
    static let minimumCalendarWidth: Double = 380
    static let resizeHandleWidth: Double = 10
    static let minimumRegularWidth: Double = 700
    static let minimumCompactLandscapeWidth: Double = 620

    static func supportsDishSidebar(
        in size: CGSize,
        horizontalSizeClass: UserInterfaceSizeClass?
    ) -> Bool {
        if horizontalSizeClass == .compact {
            return size.width > size.height && size.width >= minimumCompactLandscapeWidth
        }
        return size.width >= minimumRegularWidth
    }

    static func sidebarWidth(preferred: Double, availableWidth: Double) -> Double {
        min(
            max(preferred, minimumSidebarWidth),
            maximumSidebarWidth(availableWidth: availableWidth)
        )
    }

    static func maximumSidebarWidth(availableWidth: Double) -> Double {
        let spaceAfterCalendar = availableWidth - minimumCalendarWidth - resizeHandleWidth
        return min(maximumSidebarWidth, max(minimumSidebarWidth, spaceAfterCalendar))
    }
}

#Preview {
    NavigationStack { PlanView() }
        .environment(AppState.preview)
        .environment(PurchaseManager.shared)
        .modelContainer(PreviewData.container)
}
