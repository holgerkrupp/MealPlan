import Foundation

/// Remembers which product name a barcode stands for, on this device only.
///
/// There is no product database behind this: the first time a code is
/// scanned the person names it, and every later scan of the same code fills
/// that name in. Nothing leaves the device, and a code nobody has named yet
/// simply starts with an empty, editable name.
struct BarcodeProductMemory {
    static let defaultsKey = "barcodeProductNames"

    var defaults: UserDefaults = .standard

    /// Digits only, so the same EAN read with or without a check-digit
    /// separator or stray whitespace maps to one entry.
    static func normalize(_ code: String) -> String {
        code.filter(\.isNumber)
    }

    func name(for code: String) -> String? {
        let key = Self.normalize(code)
        guard !key.isEmpty else { return nil }
        return (defaults.dictionary(forKey: Self.defaultsKey) as? [String: String])?[key]
    }

    func remember(_ name: String, for code: String) {
        let key = Self.normalize(code)
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !trimmed.isEmpty else { return }
        var names = (defaults.dictionary(forKey: Self.defaultsKey) as? [String: String]) ?? [:]
        names[key] = trimmed
        defaults.set(names, forKey: Self.defaultsKey)
    }
}
