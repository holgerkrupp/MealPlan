import Foundation

enum BarcodeProductLookupSettings {
    static let enabledKey = "barcodeProductLookupEnabled"
    static let attributionURL = URL(string: "https://world.openfoodfacts.org/")!
    static let providerName = "Open Food Facts"
}

/// A privacy-preserving, optional lookup for a barcode. The request contains
/// only the normalized barcode; household, account and recipe data never leave
/// the device. Open Food Facts is public and optional, so the barcode flow
/// remains useful when it is disabled or unavailable.
enum BarcodeProductLookupOutcome: Equatable, Sendable {
    case found(name: String, brand: String?, source: String)
    case unknown
    case offline
    case failed
    case cancelled
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
        var lastAccess: UInt64
    }

    private let request: Request
    private let cacheLimit: Int
    private let cacheLifetime: TimeInterval
    private var cache: [String: CacheEntry] = [:]
    private var inFlight: [String: Task<BarcodeProductLookupOutcome, Never>] = [:]
    private var accessCounter: UInt64 = 0

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
            if cached.expiresAt > now {
                accessCounter &+= 1
                cache[code]?.lastAccess = accessCounter
                return cached.outcome
            }
            cache.removeValue(forKey: code)
        }
        if let task = inFlight[code] { return await task.value }

        let task = Task { [request] in
            await Self.fetch(code: code, request: request)
        }
        inFlight[code] = task
        let outcome = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            Task { await self.cancel(barcode: code) }
        }
        inFlight.removeValue(forKey: code)
        if outcome.isCacheable {
            accessCounter &+= 1
            cache[code] = CacheEntry(
                outcome: outcome,
                expiresAt: now.addingTimeInterval(cacheLifetime),
                lastAccess: accessCounter
            )
            trimCache()
        }
        return outcome
    }

    /// Cancels the shared request for a barcode. The barcode sheet calls this
    /// when it disappears or starts another scan, so a request never outlives
    /// the UI that asked for it.
    func cancel(barcode: String) {
        let code = BarcodeProductMemory.normalize(barcode)
        inFlight[code]?.cancel()
        inFlight.removeValue(forKey: code)
    }

    private func trimCache() {
        guard cache.count > cacheLimit else { return }
        let excess = cache.count - cacheLimit
        for key in cache.sorted(by: { $0.value.lastAccess < $1.value.lastAccess }).prefix(excess).map(\.key) {
            cache.removeValue(forKey: key)
        }
    }

    private static func fetch(
        code: String,
        request: Request,
    ) async -> BarcodeProductLookupOutcome {
        do {
            var urlRequest = URLRequest(url: URL(string: "https://world.openfoodfacts.org/api/v3.6/product/\(code).json?fields=code,product_name,product_name_en,brands")!)
            urlRequest.httpMethod = "GET"
            urlRequest.timeoutInterval = 8
            urlRequest.cachePolicy = .reloadIgnoringLocalCacheData
            urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
            urlRequest.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
            let response = try await request(urlRequest)
            guard (200..<300).contains(response.statusCode) else { return .failed }
            let product = try JSONDecoder().decode(ProductResponse.self, from: response.body)
            guard product.status.isFound else { return .unknown }
            let name = (product.product?.productName ?? product.product?.productNameEN ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return .unknown }
            let brand = product.product?.brands?.trimmingCharacters(in: .whitespacesAndNewlines)
            return .found(name: name, brand: brand?.isEmpty == false ? brand : nil, source: BarcodeProductLookupSettings.providerName)
        } catch is CancellationError {
            return .cancelled
        } catch let error as URLError where [.notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .timedOut].contains(error.code) {
            return .offline
        } catch {
            return .failed
        }
    }

    private static let userAgent: String = {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        return "Meals/\(version) (optional barcode lookup)"
    }()

    private static let defaultRequest: Request = { request in
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 10
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return BarcodeProductLookupResponse(statusCode: http.statusCode, body: data)
    }

    private struct ProductResponse: Decodable {
        let status: ProductStatus
        let product: Product?
    }

    private enum ProductStatus: Decodable, Sendable {
        case found
        case notFound

        var isFound: Bool { self == .found }

        init(from decoder: Decoder) throws {
            if let value = try? decoder.singleValueContainer().decode(Int.self) {
                self = value == 1 ? .found : .notFound
            } else if let value = try? decoder.singleValueContainer().decode(String.self) {
                self = value.lowercased() == "success" ? .found : .notFound
            } else {
                self = .notFound
            }
        }
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

private extension BarcodeProductLookupOutcome {
    var isCacheable: Bool {
        switch self {
        case .found, .unknown: true
        case .offline, .failed, .cancelled: false
        }
    }
}
