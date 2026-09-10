import SwiftUI

/// Picks the size, the layout and the photo for a recipe's share images, and
/// hands the finished pictures to the share sheet — all together, in order,
/// so they land as one carousel.
@MainActor
struct RecipeImageShareView: View {
    let dish: Dish
    let content: RecipeShareContent

    @State private var aspect: MealShareAspect = .portrait
    @State private var layout: RecipeImageLayout = .separate
    @State private var photoIndex = 0
    @State private var images: [RenderedImage] = []
    @State private var isRendering = false
    @State private var directory: URL?

    struct RenderedImage: Identifiable {
        let id: String
        let title: String
        let image: CGImage
        let url: URL
    }

    private struct Inputs: Equatable {
        var aspect: MealShareAspect
        var layout: RecipeImageLayout
        var photoIndex: Int
        var content: RecipeShareContent
    }

    private var photos: [DishImage] { dish.sortedImages }

    /// Rides along as the post's text where the service takes one.
    private var caption: String {
        guard content.hasWebSource, !content.sourceIsGone, let url = content.sourceURL else {
            return content.title
        }
        return "\(content.title)\n\(url.absoluteString)"
    }

    var body: some View {
        Form {
            Section {
                Picker(String(localized: "Aspect Ratio"), selection: $aspect) {
                    ForEach(MealShareAspect.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)

                Picker(String(localized: "Images"), selection: $layout) {
                    ForEach(RecipeImageLayout.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)

                if photos.count > 1 {
                    photoPicker
                }
            } footer: {
                Text(layout == .separate
                     ? "Ingredients, method and nutrition as separate images — post them together as a carousel."
                     : "The whole recipe on one image.")
            }

            Section {
                if images.isEmpty {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                    .padding(.vertical, 40)
                } else {
                    LazyVGrid(
                        columns: Array(
                            repeating: GridItem(.flexible(), spacing: 12),
                            count: aspect == .landscape || images.count == 1 ? 1 : 2
                        ),
                        spacing: 14
                    ) {
                        ForEach(images) { tile($0) }
                    }
                    .padding(.vertical, 4)
                }
            } footer: {
                if images.count > 4 {
                    Text("Mastodon takes up to four images per post.")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(String(localized: "Images"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                ShareLink(
                    items: images.map(\.url),
                    subject: Text(content.title),
                    message: Text(caption)
                ) {
                    Label(String(localized: "Share all"), systemImage: "square.and.arrow.up")
                }
                .disabled(images.isEmpty || isRendering)
            }
        }
        .task(id: Inputs(aspect: aspect, layout: layout, photoIndex: photoIndex, content: content)) {
            await render()
        }
        .onDisappear { removeDirectory() }
    }

    private var photoPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(Array(photos.enumerated()), id: \.offset) { index, photo in
                    Button {
                        photoIndex = index
                    } label: {
                        DishThumbnail(image: photo, size: 56, cornerRadius: 10)
                            .overlay {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(index == photoIndex ? Color.accentColor : .clear, lineWidth: 3)
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(localized: "Photo \(index + 1)"))
                    .accessibilityAddTraits(index == photoIndex ? .isSelected : [])
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func tile(_ rendered: RenderedImage) -> some View {
        let preview = Image(decorative: rendered.image, scale: 1)
        return VStack(spacing: 6) {
            preview
                .resizable()
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 1)
                }
            HStack {
                Text(rendered.title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                ShareLink(item: rendered.url, preview: SharePreview(rendered.title, image: preview)) {
                    Image(systemName: "square.and.arrow.up")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(String(localized: "Share \(rendered.title)"))
            }
        }
    }

    // MARK: - Rendering

    private func render() async {
        isRendering = true
        defer { isRendering = false }

        let metrics = RecipeImageMetrics(aspect: aspect)
        let photoData = photos.indices.contains(photoIndex) ? photos[photoIndex].data : nil
        let photo = photoData
            .map { ImagePreparation.prepared(from: $0, maxDimension: 1_800, quality: 0.85) }
            .flatMap(Image.init(data:))
        let pages = RecipeImagePlanner.plan(
            content: content,
            layout: layout,
            metrics: metrics,
            measure: RecipeImageRenderer.measure(content: content, metrics: metrics, glyph: dish.glyph)
        )
        guard !Task.isCancelled, let batch = try? ShareFileName.stagingDirectory() else { return }

        var rendered: [RenderedImage] = []
        for (number, page) in pages.enumerated() {
            guard !Task.isCancelled else {
                try? FileManager.default.removeItem(at: batch)
                return
            }
            guard let image = RecipeImageRenderer.render(
                page, content: content, metrics: metrics, photo: photo, glyph: dish.glyph
            ), let data = RecipeImageRenderer.jpegData(image) else { continue }

            // Numbered, so the carousel keeps its order wherever it lands.
            let name = ShareFileName.sanitized(
                "\(content.title) \(number + 1) – \(page.title)",
                fallback: String(localized: "Recipe")
            )
            let url = batch.appending(path: name).appendingPathExtension("jpg")
            guard (try? data.write(to: url, options: .atomic)) != nil else { continue }
            rendered.append(RenderedImage(id: "\(number)-\(page.id)", title: page.title, image: image, url: url))
            await Task.yield()
        }

        removeDirectory()
        directory = batch
        images = rendered
    }

    private func removeDirectory() {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
    }
}
