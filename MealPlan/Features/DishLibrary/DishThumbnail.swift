import SwiftUI
import ImageIO
import SwiftData

#if canImport(UIKit)
import UIKit
typealias PlatformImage = UIImage
#elseif canImport(AppKit)
import AppKit
typealias PlatformImage = NSImage
#endif

extension Image {
    /// Build a SwiftUI `Image` from raw photo data, cross-platform.
    init?(data: Data) {
        #if canImport(UIKit)
        guard let ui = UIImage(data: data) else { return nil }
        self.init(uiImage: ui)
        #elseif canImport(AppKit)
        guard let ns = NSImage(data: data) else { return nil }
        self.init(nsImage: ns)
        #else
        return nil
        #endif
    }
}

/// A rounded dish photo. With no photo it falls back to the dish's own
/// placeholder glyph — an emoji or SF Symbol the user picked — and only then
/// to the generic fork-and-knife.
@MainActor
struct DishThumbnail: View {
    private let imageRecord: DishImage?
    private let rawData: Data?
    var glyph: DishGlyph?
    /// Tints the glyph placeholder; derived from the dish name so each dish
    /// keeps the same colour everywhere.
    var tint: Color = .gray
    var size: CGFloat = 56
    var cornerRadius: CGFloat = 12
    private var width: CGFloat
    private var height: CGFloat
    @Environment(\.displayScale) private var displayScale

    init(
        data: Data?, glyph: DishGlyph? = nil, tint: Color = .gray,
        size: CGFloat = 56, cornerRadius: CGFloat = 12,
        width: CGFloat? = nil, height: CGFloat? = nil
    ) {
        self.imageRecord = nil
        self.rawData = data
        self.glyph = glyph
        self.tint = tint
        self.width = width ?? size
        self.height = height ?? size
        self.size = max(self.width, self.height)
        self.cornerRadius = cornerRadius
    }

    init(
        image: DishImage?, glyph: DishGlyph? = nil, tint: Color = .gray,
        size: CGFloat = 56, cornerRadius: CGFloat = 12,
        width: CGFloat? = nil, height: CGFloat? = nil
    ) {
        self.imageRecord = image
        self.rawData = nil
        self.glyph = glyph
        self.tint = tint
        self.width = width ?? size
        self.height = height ?? size
        self.size = max(self.width, self.height)
        self.cornerRadius = cornerRadius
    }

    /// Photo, glyph and tint all taken from the dish.
    init(
        dish: Dish?, size: CGFloat = 56, cornerRadius: CGFloat = 12,
        width: CGFloat? = nil, height: CGFloat? = nil
    ) {
        self.imageRecord = dish?.primaryImage
        self.rawData = nil
        self.glyph = dish?.glyph
        self.tint = DishGlyph.tint(forName: dish?.name ?? "")
        self.width = width ?? size
        self.height = height ?? size
        self.size = max(self.width, self.height)
        self.cornerRadius = cornerRadius
    }

    var body: some View {
        ZStack {
            if imageRecord == nil {
                placeholder
            } else {
                // A photo-backed dish should not flash its emoji while a
                // newly-created lazy cell obtains the already-decoded image.
                Rectangle().fill(tint.opacity(0.18))
            }
            if let imageRecord {
                CachedDishPhoto(
                    image: imageRecord,
                    cacheKey: "\(imageRecord.persistentModelID.hashValue)-\(imageRecord.modifiedAt.timeIntervalSinceReferenceDate)",
                    maxPixelSize: size * displayScale
                )
            } else if let rawData {
                CachedDishPhoto(
                    data: rawData,
                    cacheKey: Self.rawCacheKey(rawData),
                    maxPixelSize: size * displayScale
                )
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    private static func rawCacheKey(_ data: Data) -> String {
        "raw-\(data.count)-\(data.prefix(12).base64EncodedString())"
    }

    @ViewBuilder
    private var placeholder: some View {
        switch glyph {
        case .emoji(let value):
            ZStack {
                Rectangle().fill(tint.opacity(0.18))
                Text(value)
                    .font(.system(size: size * 0.52))
                    .minimumScaleFactor(0.5)
            }
        case .symbol(let name):
            ZStack {
                Rectangle().fill(tint.opacity(0.18))
                Image(systemName: name)
                    .font(.system(size: size * 0.42))
                    .foregroundStyle(tint)
            }
        case nil:
            ZStack {
                Rectangle().fill(.quaternary)
                Image(systemName: "fork.knife")
                    .font(.system(size: size * 0.4))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// The rendered-image cache is read synchronously by `body`. Lazy grids often
/// recreate an off-screen cell; an actor hop here would leave one empty frame
/// even when its photo was already cached, which looks like flicker.
@MainActor
private final class DishPhotoMemoryCache {
    static let shared = DishPhotoMemoryCache()
    private let images = NSCache<NSString, CGImage>()

    private init() {
        images.totalCostLimit = 96 * 1024 * 1024
        images.countLimit = 240
    }

    func image(for key: String) -> CGImage? {
        images.object(forKey: key as NSString)
    }

    func insert(_ image: CGImage, for key: String) {
        images.setObject(image, forKey: key as NSString, cost: image.bytesPerRow * image.height)
    }
}

/// JPEG/HEIF decoding stays serialized and off the main actor. The separate
/// memory cache above is intentionally main-actor-owned for zero-latency reads
/// while SwiftUI builds a frame.
private actor DishPhotoDecoder {
    static let shared = DishPhotoDecoder()

    func image(data: Data, maxPixelSize: CGFloat) -> CGImage? {
        guard !Task.isCancelled else { return nil }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

struct CachedDishPhoto: View {
    private let imageID: PersistentIdentifier?
    private let rawData: Data?
    let cacheKey: String
    let maxPixelSize: CGFloat

    @State private var decoded: CGImage?
    @State private var decodedKey: String?
    @Environment(\.modelContext) private var modelContext

    private var sizedKey: String {
        "\(cacheKey)-\(Int(maxPixelSize.rounded(.up)))"
    }

    init(image: DishImage, cacheKey: String, maxPixelSize: CGFloat) {
        self.imageID = image.persistentModelID
        self.rawData = nil
        self.cacheKey = cacheKey
        self.maxPixelSize = maxPixelSize
    }

    init(data: Data, cacheKey: String, maxPixelSize: CGFloat) {
        self.imageID = nil
        self.rawData = data
        self.cacheKey = cacheKey
        self.maxPixelSize = maxPixelSize
    }

    var body: some View {
        let visibleImage = decodedKey == sizedKey
            ? decoded
            : DishPhotoMemoryCache.shared.image(for: sizedKey)

        Group {
            if let visibleImage {
                Image(decorative: visibleImage, scale: 1)
                    .resizable()
                    .scaledToFill()
            } else {
                Color.clear
            }
        }
        .task(id: sizedKey) {
            if let cached = DishPhotoMemoryCache.shared.image(for: sizedKey) {
                decoded = cached
                decodedKey = sizedKey
                return
            }
            let sourceData: Data?
            if let imageID {
                let loader = DishPhotoDataActor(modelContainer: modelContext.container)
                sourceData = await loader.data(for: imageID)
            } else {
                sourceData = rawData
            }
            guard !Task.isCancelled, let sourceData else { return }
            let image = await DishPhotoDecoder.shared.image(
                data: sourceData,
                maxPixelSize: max(1, maxPixelSize)
            )
            guard !Task.isCancelled, let image else { return }
            DishPhotoMemoryCache.shared.insert(image, for: sizedKey)
            decoded = image
            decodedKey = sizedKey
        }
    }
}

/// External-storage faults can involve disk I/O and decompression. Resolve the
/// photo bytes on a SwiftData executor rather than inside the scrolling view's
/// main-actor task.
@ModelActor
actor DishPhotoDataActor {
    func data(for imageID: PersistentIdentifier) -> Data? {
        (modelContext.model(for: imageID) as? DishImage)?.data
    }
}

#Preview {
    HStack(spacing: 12) {
        DishThumbnail(data: nil, size: 72)
        DishThumbnail(data: nil, glyph: .emoji("🍝"), tint: .orange, size: 72)
        DishThumbnail(data: nil, glyph: .symbol("carrot.fill"), tint: .green, size: 72)
    }
    .padding()
}
