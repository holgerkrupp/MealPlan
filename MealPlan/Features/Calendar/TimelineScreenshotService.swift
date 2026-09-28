#if os(iOS)
import SwiftUI
import UIKit

/// Supplies the calendar's scrollable plan to the iOS screenshot markup UI.
@MainActor
final class TimelineScreenshotService: NSObject, UIScreenshotServiceDelegate {
    private weak var scrollView: UIScrollView?
    private weak var contentView: UIView?
    private weak var previousService: TimelineScreenshotService?

    func update(scrollView: UIScrollView?, contentView: UIView?) {
        self.scrollView = scrollView
        self.contentView = contentView

        // The service is scene-owned and its delegate is weak. Keeping this
        // object alive in the bridge coordinator is therefore intentional.
        guard let screenshotService = scrollView?.window?.windowScene?.screenshotService else { return }
        if let current = screenshotService.delegate as? TimelineScreenshotService, current !== self {
            previousService = current
        }
        screenshotService.delegate = self
    }

    func detach() {
        if let scene = scrollView?.window?.windowScene,
           scene.screenshotService?.delegate === self {
            scene.screenshotService?.delegate = previousService
        }
        previousService = nil
        scrollView = nil
        contentView = nil
    }

    func screenshotService(
        _ screenshotService: UIScreenshotService,
        generatePDFRepresentationWithCompletion completionHandler: @escaping (Data?, Int, CGRect) -> Void
    ) {
        guard let scrollView, let contentView else {
            completionHandler(nil, 0, .zero)
            return
        }

        let data: Data?
        let pageSize: CGSize
        if contentView === scrollView {
            // SwiftUI List is backed by a UITableView and only keeps the
            // nearby rows alive. Capture viewport-sized slices while walking
            // through it so off-screen shopping rows are materialized too.
            let contentSize = scrollView.contentSize
            let viewportSize = scrollView.bounds.size
            guard contentSize.width > 0, contentSize.height > 0,
                  viewportSize.width > 0, viewportSize.height > 0 else {
                completionHandler(nil, 0, .zero)
                return
            }
            pageSize = CGSize(width: max(contentSize.width, viewportSize.width), height: contentSize.height)
            let originalOffset = scrollView.contentOffset
            data = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: pageSize)).pdfData { context in
                context.beginPage()
                var offsetY: CGFloat = 0
                let maximumOffsetY = max(0, contentSize.height - viewportSize.height)
                while offsetY < pageSize.height {
                    let actualOffsetY = min(offsetY, maximumOffsetY)
                    scrollView.setContentOffset(CGPoint(x: originalOffset.x, y: actualOffsetY), animated: false)
                    scrollView.layoutIfNeeded()
                    CATransaction.flush()

                    context.cgContext.saveGState()
                    context.cgContext.translateBy(x: 0, y: actualOffsetY)
                    scrollView.drawHierarchy(in: scrollView.bounds, afterScreenUpdates: true)
                    context.cgContext.restoreGState()
                    offsetY += viewportSize.height

                    // The last viewport is clamped to the table's maximum
                    // offset; it already reaches the end of the PDF page.
                    if actualOffsetY == maximumOffsetY { break }
                }
                scrollView.setContentOffset(originalOffset, animated: false)
                scrollView.layoutIfNeeded()
            }
        } else {
            let contentBounds = contentView.bounds
            guard contentBounds.width > 0, contentBounds.height > 0 else {
                completionHandler(nil, 0, .zero)
                return
            }
            pageSize = contentBounds.size
            let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: pageSize))
            data = renderer.pdfData { context in
                context.beginPage()

                // Render the content view in its own coordinate space.
                // Rendering the scroll view itself would retain its viewport
                // clipping and would therefore produce an ordinary shot.
                contentView.layer.render(in: context.cgContext)
            }
        }

        let visibleRect = CGRect(
            x: scrollView.contentOffset.x,
            y: scrollView.contentOffset.y,
            width: min(scrollView.bounds.width, pageSize.width),
            height: min(scrollView.bounds.height, pageSize.height)
        )
        completionHandler(data, 0, visibleRect)
    }
}

/// A zero-size marker placed inside the timeline's scroll content.
///
/// SwiftUI does not expose the underlying `UIScrollView`, so the marker walks
/// its UIKit ancestors and gives the screenshot service the exact content
/// view to render. It is kept in the scroll content (rather than as a
/// background of `ScrollView`) so this remains true across SwiftUI releases.
struct TimelineScreenshotBridge: UIViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MarkerView {
        let view = MarkerView()
        view.onMoveToWindow = { [weak coordinator = context.coordinator] marker in
            coordinator?.update(for: marker)
        }
        return view
    }

    func updateUIView(_ uiView: MarkerView, context: Context) {
        context.coordinator.update(for: uiView)
    }

    static func dismantleUIView(_ uiView: MarkerView, coordinator: Coordinator) {
        coordinator.service.detach()
    }

    @MainActor
    final class Coordinator {
        let service = TimelineScreenshotService()

        func update(for marker: MarkerView) {
            guard let scrollView = marker.enclosingScrollView else {
                service.detach()
                return
            }

            var contentView: UIView = marker
            while let parent = contentView.superview, parent !== scrollView {
                contentView = parent
            }
            guard contentView.superview === scrollView else {
                service.detach()
                return
            }
            // SwiftUI List's immediate scroll child is a virtualized table or
            // collection cell, not the full document. Ask the service to walk
            // the list viewport instead of rendering that one cell.
            let isVirtualizedList = scrollView is UITableView
                || scrollView is UICollectionView
            service.update(
                scrollView: scrollView,
                contentView: isVirtualizedList ? scrollView : contentView
            )
        }
    }

    @MainActor
    final class MarkerView: UIView {
        var onMoveToWindow: ((MarkerView) -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            onMoveToWindow?(self)
        }

        var enclosingScrollView: UIScrollView? {
            var view = superview
            while let current = view {
                if let scrollView = current as? UIScrollView {
                    return scrollView
                }
                view = current.superview
            }
            return nil
        }
    }
}

/// The bridge is shared by every full-page document in the iOS app. The
/// timeline was its first consumer, but recipes and the shopping list use the
/// same scene screenshot service contract.
typealias FullPageScreenshotBridge = TimelineScreenshotBridge
#endif
