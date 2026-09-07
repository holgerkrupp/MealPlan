import SwiftUI

/// A feed article's photo, drawn to match `DishThumbnail` so an article card
/// and a dish card are the same object at a glance.
///
/// The bytes are downloaded once per URL and then handed to the very same
/// downsampling decoder and memory cache the library's own photos use, so a
/// grid of remote images costs no more than a grid of local ones.
@MainActor
struct RemoteRecipeImage: View {
    let url: URL?
    /// Drawn while the photo is missing or still arriving. Matches the glyph
    /// placeholder of a dish with no picture.
    var placeholderSymbol: String = "newspaper"
    var tint: Color = .gray
    var cornerRadius: CGFloat = 12
    var width: CGFloat
    var height: CGFloat

    @Environment(\.displayScale) private var displayScale
    @State private var data: Data?

    private var maxPixelSize: CGFloat { max(width, height) * displayScale }

    var body: some View {
        ZStack {
            Rectangle().fill(tint.opacity(0.18))
            if data == nil {
                Image(systemName: placeholderSymbol)
                    .font(.system(size: max(width, height) * 0.28))
                    .foregroundStyle(.secondary)
            }
            if let data {
                CachedDishPhoto(
                    data: data,
                    cacheKey: RemoteRecipeImageLoader.cacheKey(for: url),
                    maxPixelSize: maxPixelSize
                )
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .task(id: url) {
            data = await RemoteRecipeImageLoader.shared.data(for: url)
        }
    }
}

/// Keeps the compressed bytes of recently seen article photos in memory.
///
/// `CachedDishPhoto` caches the *decoded* image, but only per pixel size — the
/// same photo shown as a card and then as a detail hero would otherwise be
/// downloaded twice. Coalescing in-flight requests matters just as much: a
/// `LazyVGrid` builds, discards and rebuilds the same cell repeatedly while the
/// user scrolls.
actor RemoteRecipeImageLoader {
    static let shared = RemoteRecipeImageLoader()

    private var cached: [URL: Data] = [:]
    private var order: [URL] = []
    private var inFlight: [URL: Task<Data?, Never>] = [:]

    private let byteLimit = 24 * 1_024 * 1_024
    private let countLimit = 80
    /// Feed photos are routinely 1–2 MB. Anything larger is a page banner or a
    /// mistake, and is not worth the memory to show in a 200pt card.
    private let maxImageBytes = 8 * 1_024 * 1_024

    nonisolated static func cacheKey(for url: URL?) -> String {
        "feed-\(url?.absoluteString ?? "none")"
    }

    func data(for url: URL?) async -> Data? {
        guard let url, url.scheme?.lowercased().hasPrefix("http") == true else { return nil }
        if let hit = cached[url] { return hit }
        if let running = inFlight[url] { return await running.value }

        let task = Task<Data?, Never> { [maxImageBytes] in
            var request = URLRequest(url: url)
            request.setValue("image/*", forHTTPHeaderField: "Accept")
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  http.mimeType?.hasPrefix("image/") == true,
                  data.count <= maxImageBytes,
                  !data.isEmpty else { return nil }
            return data
        }
        inFlight[url] = task
        let data = await task.value
        inFlight[url] = nil
        if let data { store(data, for: url) }
        return data
    }

    private func store(_ data: Data, for url: URL) {
        cached[url] = data
        order.removeAll { $0 == url }
        order.append(url)
        var bytes = order.reduce(0) { $0 + (cached[$1]?.count ?? 0) }
        while order.count > countLimit || (bytes > byteLimit && order.count > 1) {
            let evicted = order.removeFirst()
            bytes -= cached.removeValue(forKey: evicted)?.count ?? 0
        }
    }
}
