import Foundation

/// A privacy-preserving, optional lookup for a barcode. The request contains
/// only the normalized barcode; household, account and recipe data never leave
/// the device. Open Food Facts is public and optional, so the barcode flow
/// remains useful when it is disabled or unavailable.
enum BarcodeProductLookupOutcome: Equatable, Sendable {
    case found(name: String, brand: String?, source: String)
    case unknown
    case offline
    case failed
}

struct BarcodeProductLookupResponse: Sendable {
    let statusCode: Int
    let body: Data
}

actor BarcodeProductLookup {
    typealias Request = @Sendable (URLRequest) async throws -> BarcodeProductLookupResponse

    static let shared = BarcodeProductLookup()

    private struct CacheEntry: Sendable {
        let outcome: BarcodeProductLookupOutcome
        let expiresAt: Date
    }

    private let request: Request
    private let cacheLimit: Int
    private let cacheLifetime: TimeInterval
    private var cache: [String: CacheEntry] = [:]
    private var inFlight: [String: Task<BarcodeProductLookupOutcome, Never>] = [:]

    init(
        cacheLimit: Int = 128,
        cacheLifetime: TimeInterval = 60 * 60 * 24 * 30,
        request: @escaping Request = BarcodeProductLookup.defaultRequest
    ) {
        self.cacheLimit = max(1, cacheLimit)
        self.cacheLifetime = max(1, cacheLifetime)
        self.request = request
    }

    func lookup(barcode: String, now: Date = .now) async -> BarcodeProductLookupOutcome {
        let code = BarcodeProductMemory.normalize(barcode)
        guard !code.isEmpty else { return .unknown }

        if let cached = cache[code] {
            if cached.expiresAt > now { return cached.outcome }
            cache.removeValue(forKey: code)
        }
        if let task = inFlight[code] { return await task.value }

        let task = Task { [request, cacheLifetime] in
            await Self.fetch(code: code, request: request, cacheLifetime: cacheLifetime)
        }
        inFlight[code] = task
        let outcome = await task.value
        inFlight.removeValue(forKey: code)
        cache[code] = CacheEntry(outcome: outcome, expiresAt: now.addingTimeInterval(cacheLifetime))
        trimCache()
        return outcome
    }

    private func trimCache() {
        guard cache.count > cacheLimit else { return }
        let excess = cache.count - cacheLimit
        for key in cache.sorted(by: { $0.value.expiresAt < $1.value.expiresAt }).prefix(excess).map(\.key) {
            cache.removeValue(forKey: key)
        }
    }

    private static func fetch(
        code: String,
        request: Request,
        cacheLifetime: TimeInterval
    ) async -> BarcodeProductLookupOutcome {
        do {
            var urlRequest = URLRequest(url: URL(string: "https://world.openfoodfacts.org/api/v2/product/\(code).json?fields=product_name,product_name_en,brands")!)
            urlRequest.httpMethod = "GET"
            urlRequest.timeoutInterval = 4
            urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
            let response = try await request(urlRequest)
            guard (200..<300).contains(response.statusCode) else { return .failed }
            let product = try JSONDecoder().decode(ProductResponse.self, from: response.body)
            guard product.status == 1 else { return .unknown }
            let name = (product.product?.productName ?? product.product?.productNameEN ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return .unknown }
            let brand = product.product?.brands?.trimmingCharacters(in: .whitespacesAndNewlines)
            return .found(name: name, brand: brand?.isEmpty == false ? brand : nil, source: "Open Food Facts")
        } catch is CancellationError {
            return .failed
        } catch let error as URLError where [.notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .timedOut].contains(error.code) {
            return .offline
        } catch {
            return .failed
        }
    }

    private static let defaultRequest: Request = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return BarcodeProductLookupResponse(statusCode: http.statusCode, body: data)
    }

    private struct ProductResponse: Decodable {
        let status: Int
        let product: Product?
    }

    private struct Product: Decodable {
        let productName: String?
        let productNameEN: String?
        let brands: String?

        enum CodingKeys: String, CodingKey {
            case productName = "product_name"
            case productNameEN = "product_name_en"
            case brands
        }
    }
}
