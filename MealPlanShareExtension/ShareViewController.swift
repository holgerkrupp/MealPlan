import UIKit
import SwiftUI
import UniformTypeIdentifiers

/// Entry point for the "Share to MealPlan" sheet. Pulls the URL / text / file
/// out of the extension context and hands it to `ShareRootView`.
final class ShareViewController: UIViewController {

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        Task { await loadAndPresent() }
    }

    private func loadAndPresent() async {
        let payload = await Self.extractPayload(from: extensionContext)
        let root = ShareRootView(payload: payload) { [weak self] in
            self?.finish()
        }
        let host = UIHostingController(rootView: root)
        host.modalPresentationStyle = .automatic
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
    }

    private func finish() {
        extensionContext?.completeRequest(returningItems: nil)
    }

    // MARK: - Payload extraction

    static func extractPayload(from context: NSExtensionContext?) async -> SharePayload {
        guard let items = context?.inputItems as? [NSExtensionItem] else { return .empty }
        for item in items {
            for provider in item.attachments ?? [] {
                // Paprika's own identifiers first — this is what its share
                // sheet actually registers.
                for identifier in RecipeFileType.paprikaIdentifiers
                where provider.hasItemConformingToTypeIdentifier(identifier) {
                    if let data = await loadFileData(provider, type: identifier) {
                        return .paprika(data)
                    }
                }
                if provider.hasItemConformingToTypeIdentifier(RecipeFileType.mealPlanIdentifier),
                   let data = await loadFileData(provider, type: RecipeFileType.mealPlanIdentifier) {
                    return .mealPlan(data)
                }
                if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
                   let url = await loadURL(provider, type: UTType.fileURL.identifier) {
                    if RecipeFileType.isMealPlanArchive(url), let data = try? Data(contentsOf: url) {
                        return .mealPlan(data)
                    }
                    if RecipeFileType.isImportable(url), let data = try? Data(contentsOf: url) {
                        return .paprika(data)
                    }
                }
                if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
                   let url = await loadURL(provider, type: UTType.url.identifier),
                   url.scheme?.hasPrefix("http") == true {
                    return .url(url)
                }
                if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                   let text = await loadText(provider) {
                    if let url = firstURL(in: text) { return .url(url) }
                    return .text(text)
                }
                // Last resort: an opaque `public.data` attachment with no
                // recognisable type. Accept it only when the bytes really do
                // decode as a recipe archive, so the activation rule's wide
                // `public.data` clause can't drag unrelated files in.
                if provider.hasItemConformingToTypeIdentifier(UTType.data.identifier),
                   let data = await loadFileData(provider, type: UTType.data.identifier) {
                    if (try? MealPlanRecipeArchive.importedRecipes(from: data)) != nil {
                        return .mealPlan(data)
                    }
                    if (try? PaprikaArchive.recipes(from: data)) != nil {
                        return .paprika(data)
                    }
                }
            }
            if let text = item.attributedContentText?.string, !text.isEmpty {
                if let url = firstURL(in: text) { return .url(url) }
                return .text(text)
            }
        }
        return .empty
    }

    private static func loadURL(_ provider: NSItemProvider, type: String) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadObject(ofClass: NSURL.self) { object, _ in
                continuation.resume(returning: (object as? NSURL).map { $0 as URL })
            }
        }
    }

    private static func loadText(_ provider: NSItemProvider) async -> String? {
        await withCheckedContinuation { continuation in
            provider.loadObject(ofClass: NSString.self) { object, _ in
                continuation.resume(returning: (object as? NSString).map { $0 as String })
            }
        }
    }

    private static func loadFileData(_ provider: NSItemProvider, type: String) async -> Data? {
        await withCheckedContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in
                continuation.resume(returning: data)
            }
        }
    }

    private static func firstURL(in text: String) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        return detector.firstMatch(in: text, range: range)?.url.flatMap {
            $0.scheme?.hasPrefix("http") == true ? $0 : nil
        }
    }
}

enum SharePayload {
    case url(URL)
    case text(String)
    case paprika(Data)
    case mealPlan(Data)
    case empty
}
