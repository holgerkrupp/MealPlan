import Foundation

/// Fetches something a web page or a pasted link pointed at, without trusting
/// its size or its scheme. It goes to a file first, so an oversized response is
/// turned away before it ever reaches memory; the Share Extension in particular
/// would be killed long before an error could be shown.
enum BoundedDownload {
    static let maxBytes = 20 * 1_024 * 1_024

    static func data(
        for request: URLRequest,
        session: URLSession = .shared,
        maxBytes: Int = maxBytes
    ) async throws -> (Data, URLResponse) {
        guard let scheme = request.url?.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw RecipeImportError.notReachable
        }
        let (file, response) = try await session.download(for: request)
        defer { try? FileManager.default.removeItem(at: file) }
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? .max
        guard size <= maxBytes else { throw RecipeImportError.notReachable }
        return (try Data(contentsOf: file), response)
    }
}
