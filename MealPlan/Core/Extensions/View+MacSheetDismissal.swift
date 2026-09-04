import SwiftUI

extension View {
    /// Makes transient SwiftUI sheets behave like Mac popovers: a click in
    /// another window (including the disabled parent) puts the sheet away.
    /// Other platforms retain their native presentation behaviour.
    @ViewBuilder
    func dismissesOnOutsideClick() -> some View {
        #if os(macOS)
        modifier(MacSheetOutsideClickModifier())
        #else
        self
        #endif
    }
}

#if os(macOS)
import AppKit

private struct MacSheetOutsideClickModifier: ViewModifier {
    @Environment(\.dismiss) private var dismiss

    func body(content: Content) -> some View {
        content.background {
            SheetWindowReader(dismiss: { dismiss() })
                .frame(width: 0, height: 0)
        }
    }
}

private struct SheetWindowReader: NSViewRepresentable {
    let dismiss: @MainActor () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(dismiss: dismiss)
    }

    func makeNSView(context: Context) -> WindowObservingView {
        let view = WindowObservingView()
        view.windowDidChange = { [weak coordinator = context.coordinator] window in
            coordinator?.attach(to: window)
        }
        return view
    }

    func updateNSView(_ view: WindowObservingView, context: Context) {
        context.coordinator.dismiss = dismiss
        context.coordinator.attach(to: view.window)
    }

    static func dismantleNSView(_ view: WindowObservingView, coordinator: Coordinator) {
        coordinator.stop()
    }

    @MainActor
    final class Coordinator {
        weak var sheetWindow: NSWindow?
        var dismiss: @MainActor () -> Void
        private var eventMonitor: Any?
        private var resignObserver: NSObjectProtocol?

        init(dismiss: @escaping @MainActor () -> Void) {
            self.dismiss = dismiss
        }

        func attach(to window: NSWindow?) {
            guard let window, window !== sheetWindow else { return }
            stop()
            sheetWindow = window

            eventMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
            ) { [weak self] event in
                guard let self, let sheetWindow = self.sheetWindow else { return event }
                guard !Self.isWindow(event.window, inside: sheetWindow) else { return event }
                // Defer changing the window hierarchy until AppKit has
                // finished dispatching the mouse-down that triggered it.
                Task { @MainActor [weak self] in self?.dismiss() }
                // The click's purpose was to dismiss the transient surface;
                // don't also activate a control underneath it.
                return nil
            }

            resignObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didResignActiveNotification,
                object: NSApp,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.dismiss() }
            }
        }

        func stop() {
            if let eventMonitor {
                NSEvent.removeMonitor(eventMonitor)
                self.eventMonitor = nil
            }
            if let resignObserver {
                NotificationCenter.default.removeObserver(resignObserver)
                self.resignObserver = nil
            }
            sheetWindow = nil
        }

        private static func isWindow(_ candidate: NSWindow?, inside sheet: NSWindow) -> Bool {
            var window = candidate
            while let current = window {
                if current === sheet { return true }
                window = current.sheetParent
            }
            return false
        }
    }
}

@MainActor
private final class WindowObservingView: NSView {
    var windowDidChange: ((NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowDidChange?(window)
    }
}
#endif
