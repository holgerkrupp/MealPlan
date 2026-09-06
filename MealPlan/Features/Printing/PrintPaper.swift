import CoreGraphics
import Foundation

/// A paper size, in the only unit a PDF cares about: PostScript points at
/// 72 dpi, which is also what `ImageRenderer` lays a SwiftUI view out in.
///
/// Sizes are stated portrait — width before height — and `PrintPageGeometry`
/// turns them round for landscape. The list is deliberately short: the
/// standards a household printer actually has in its tray, ISO A and US
/// alike, because MealPlan ships on both sides of the Atlantic.
enum PaperSize: String, CaseIterable, Identifiable, Codable, Sendable {
    case a3
    case a4
    case a5
    case letter
    case legal
    case tabloid

    var id: String { rawValue }

    /// Portrait size in points. The ISO sizes are the millimetre dimensions
    /// converted at 72 dpi and rounded to whole points, which is what every
    /// PDF producer does — a fraction of a point is far below what a printer
    /// can place ink at.
    var portraitPoints: CGSize {
        switch self {
        case .a3: CGSize(width: 842, height: 1_191)
        case .a4: CGSize(width: 595, height: 842)
        case .a5: CGSize(width: 420, height: 595)
        case .letter: CGSize(width: 612, height: 792)
        case .legal: CGSize(width: 612, height: 1_008)
        case .tabloid: CGSize(width: 792, height: 1_224)
        }
    }

    var localizedName: String {
        switch self {
        case .a3: String(localized: "A3")
        case .a4: String(localized: "A4")
        case .a5: String(localized: "A5")
        case .letter: String(localized: "US Letter")
        case .legal: String(localized: "US Legal")
        case .tabloid: String(localized: "US Tabloid")
        }
    }

    /// The size spelled out, for the picker's second line — nobody remembers
    /// whether A5 is bigger or smaller than Letter.
    var dimensionsText: String {
        switch self {
        case .a3: String(localized: "297 × 420 mm")
        case .a4: String(localized: "210 × 297 mm")
        case .a5: String(localized: "148 × 210 mm")
        case .letter: String(localized: "8.5 × 11 in")
        case .legal: String(localized: "8.5 × 14 in")
        case .tabloid: String(localized: "11 × 17 in")
        }
    }
}

enum PrintOrientation: String, CaseIterable, Identifiable, Codable, Sendable {
    case portrait
    case landscape

    var id: String { rawValue }

    var localizedName: String {
        switch self {
        case .portrait: String(localized: "Portrait")
        case .landscape: String(localized: "Landscape")
        }
    }

    var symbolName: String {
        switch self {
        case .portrait: "doc"
        case .landscape: "doc.badge.ellipsis"
        }
    }
}

/// One page's measurements: the sheet, the margin, and what is left to draw in.
///
/// The margin is fixed rather than settable. Every consumer printer keeps a
/// non-printable border of roughly a centimetre, so anything smaller would be
/// a setting that silently doesn't work; A5 gets a tighter one because a
/// 36-point margin on a small sheet eats a fifth of the page.
struct PrintPageGeometry: Equatable, Sendable {
    var paper: PaperSize
    var orientation: PrintOrientation

    var size: CGSize {
        let portrait = paper.portraitPoints
        return switch orientation {
        case .portrait: portrait
        case .landscape: CGSize(width: portrait.height, height: portrait.width)
        }
    }

    var margin: CGFloat {
        paper == .a5 ? 22 : 32
    }

    var contentSize: CGSize {
        CGSize(width: size.width - 2 * margin, height: size.height - 2 * margin)
    }

    /// What the title line at the top and the footnote at the bottom leave for
    /// the body. Used by anything that has to lay itself out before it is
    /// rendered — the shopping list's columns, mainly.
    var bodyHeight: CGFloat {
        contentSize.height - 42 * textScale
    }

    /// Body text scales with the sheet so an A5 page isn't a shrunk A4 with
    /// unreadably thin columns — and an A3 sheet on the kitchen wall is
    /// legible from across the room.
    var textScale: CGFloat {
        switch paper {
        case .a5: 0.86
        case .a4, .letter, .legal: 1
        case .a3, .tabloid: 1.3
        }
    }
}
