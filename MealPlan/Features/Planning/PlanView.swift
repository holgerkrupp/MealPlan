import SwiftUI
import SwiftData

/// The Plan section. On compact widths it is just the calendar; everywhere
/// else (iPad, Mac, phone in landscape) the calendar keeps the leading side
/// and a searchable dish list sits on the trailing side, so dishes can be
/// dragged straight onto a meal card. The divider between them is draggable
/// and the width is remembered.
@MainActor
struct PlanView: View {
    @Environment(\.horizontalSizeClass) private var sizeClass

    @AppStorage("plan.showsDishSidebar") private var showsSidebar = true
    @AppStorage("plan.dishSidebarWidth") private var sidebarWidth: Double = 300
    @State private var dragStartWidth: Double?

    private static let minWidth: Double = 220
    private static let maxWidth: Double = 460
    /// Below this the split would squeeze the calendar too hard, so we stay
    /// single-column even though the size class says "regular".
    private static let minTotalWidth: CGFloat = 700

    var body: some View {
        if sizeClass == .compact {
            CalendarHomeView()
        } else {
            splitLayout
        }
    }

    private var splitLayout: some View {
        GeometryReader { geometry in
            let fits = geometry.size.width >= Self.minTotalWidth
            let width = min(max(sidebarWidth, Self.minWidth), min(Self.maxWidth, geometry.size.width / 2))

            HStack(spacing: 0) {
                CalendarHomeView()
                    .frame(maxWidth: .infinity)

                if fits && showsSidebar {
                    resizeHandle
                    DishSidebarView()
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
                    ToolbarItem(placement: .primaryAction) {
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
            }
        }
    }

    private var resizeHandle: some View {
        Divider()
            .frame(width: 10)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let start = dragStartWidth ?? sidebarWidth
                        if dragStartWidth == nil { dragStartWidth = start }
                        sidebarWidth = min(max(start - Double(value.translation.width), Self.minWidth), Self.maxWidth)
                    }
                    .onEnded { _ in dragStartWidth = nil }
            )
            #if os(macOS)
            .pointerStyle(.columnResize)
            #endif
            .accessibilityLabel(String(localized: "Resize dish list"))
    }
}

#Preview {
    NavigationStack { PlanView() }
        .environment(AppState.preview)
        .environment(PurchaseManager.shared)
        .modelContainer(PreviewData.container)
}
