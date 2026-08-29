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
                if provider.hasItemConformingToTypeIdentifier("com.paprika.recipes"),
                   let data = await loadFileData(provider, type: "com.paprika.recipes") {
                    return .paprika(data)
                }
                if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
                   let url = await loadURL(provider, type: UTType.fileURL.identifier) {
                    if ["paprikarecipes", "paprikarecipe"].contains(url.pathExtension.lowercased()),
                       let data = try? Data(contentsOf: url) {
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
            provider.loadItem(forTypeIdentifier: type) { item, _ in
                if let url = item as? URL { continuation.resume(returning: url) }
                else if let data = item as? Data, let s = String(data: data, encoding: .utf8) {
                    continuation.resume(returning: URL(string: s.trimmingCharacters(in: .whitespacesAndNewlines)))
                } else { continuation.resume(returning: nil) }
            }
        }
    }

    private static func loadText(_ provider: NSItemProvider) async -> String? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) { item, _ in
                continuation.resume(returning: (item as? String) ?? (item as? Data).flatMap { String(data: $0, encoding: .utf8) })
            }
        }
    }

    private static func loadFileData(_ provider: NSItemProvider, type: String) async -> Data? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: type) { item, _ in
                if let url = item as? URL { continuation.resume(returning: try? Data(contentsOf: url)) }
                else if let data = item as? Data { continuation.resume(returning: data) }
                else { continuation.resume(returning: nil) }
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
    case empty
}
