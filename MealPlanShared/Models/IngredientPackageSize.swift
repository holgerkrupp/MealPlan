import Foundation
import SwiftData

/// A household-owned package-size adjustment.
///
/// Bundled package sizes live in `IngredientPackageSeedData` so an app update
/// can change its catalogue without overwriting anything a household entered.
/// A row with `overridesBundledID` shadows one bundled row; a row with
/// `overridesProfile == true` replaces the complete bundled profile for its
/// ingredient and region.
@Model
final class IngredientPackageSize {
    var uuid: UUID = UUID()
    var modifiedAt: Date = Date.now
    /// `IngredientMatching.key(for:)`, rather than a localized display name.
    var ingredientKey: String = ""
    var ingredientName: String = ""
    var countryCode: String = "DE"
    var quantityValue: Double = 0
    var quantityDimensionRaw: String = QuantityDimension.mass.rawValue
    var containerTypeRaw: String = PackageContainerType.other.rawValue
    var priorityRaw: String = PackageSizePriority.common.rawValue
    var provenanceRaw: String = PackageSizeProvenance.user.rawValue
    var sourceNote: String?
    var sourceDate: Date?
    var sourceVersion: String?
    var stableBundledID: String?
    var overridesBundledID: String?
    var overridesProfile: Bool = false
    var isEnabled: Bool = true
    var isPreferred: Bool = false

    var household: Household?

    init(
        ingredientKey: String,
        ingredientName: String,
        countryCode: String,
        quantity: Quantity,
        containerType: PackageContainerType = .other,
        priority: PackageSizePriority = .common,
        provenance: PackageSizeProvenance = .user
    ) {
        self.ingredientKey = ingredientKey
        self.ingredientName = ingredientName
        self.countryCode = countryCode.uppercased()
        self.quantityValue = quantity.value
        self.quantityDimensionRaw = quantity.dimension.rawValue
        self.containerTypeRaw = containerType.rawValue
        self.priorityRaw = priority.rawValue
        self.provenanceRaw = provenance.rawValue
    }

    var quantity: Quantity? {
        guard let dimension = QuantityDimension(rawValue: quantityDimensionRaw),
              quantityValue.isFinite, quantityValue > 0
        else { return nil }
        return Quantity(value: quantityValue, dimension: dimension)
    }

    var dimension: QuantityDimension? { QuantityDimension(rawValue: quantityDimensionRaw) }
    var containerType: PackageContainerType {
        get { PackageContainerType(rawValue: containerTypeRaw) ?? .other }
        set { containerTypeRaw = newValue.rawValue }
    }
    var priority: PackageSizePriority {
        get { PackageSizePriority(rawValue: priorityRaw) ?? .common }
        set { priorityRaw = newValue.rawValue }
    }
    var provenance: PackageSizeProvenance {
        get { PackageSizeProvenance(rawValue: provenanceRaw) ?? .user }
        set { provenanceRaw = newValue.rawValue }
    }
}

enum PackageContainerType: String, CaseIterable, Codable, Identifiable, Sendable {
    case can, jar, bottle, bag, carton, piece, tub, tube, pack, other
    var id: String { rawValue }
}

enum PackageSizePriority: String, CaseIterable, Codable, Identifiable, Sendable {
    case common, alternative
    var id: String { rawValue }
}

enum PackageSizeProvenance: String, CaseIterable, Codable, Identifiable, Sendable {
    case bundled, user, learned
    var id: String { rawValue }
}

/// The non-persisted form used by the deterministic catalogue and planner.
struct PackageSizeDefinition: Equatable, Sendable, Identifiable {
    var id: String
    var ingredientKey: String
    var ingredientName: String
    var countryCode: String
    var quantity: Quantity
    var containerType: PackageContainerType
    var priority: PackageSizePriority
    var provenance: PackageSizeProvenance
    var sourceNote: String?
    var sourceDate: Date?
    var sourceVersion: String?
    var isEnabled: Bool
    var isPreferred: Bool

    init(
        id: String,
        ingredientName: String,
        countryCode: String,
        quantity: Quantity,
        containerType: PackageContainerType,
        priority: PackageSizePriority = .common,
        provenance: PackageSizeProvenance = .bundled,
        sourceNote: String? = nil,
        sourceDate: Date? = nil,
        sourceVersion: String? = nil,
        isEnabled: Bool = true,
        isPreferred: Bool = false
    ) {
        self.id = id
        self.ingredientName = ingredientName
        self.ingredientKey = IngredientMatching.key(for: ingredientName)
        self.countryCode = countryCode.uppercased()
        self.quantity = quantity
        self.containerType = containerType
        self.priority = priority
        self.provenance = provenance
        self.sourceNote = sourceNote
        self.sourceDate = sourceDate
        self.sourceVersion = sourceVersion
        self.isEnabled = isEnabled
        self.isPreferred = isPreferred
    }

    init(_ model: IngredientPackageSize) {
        self.init(
            id: model.stableBundledID ?? model.uuid.uuidString,
            ingredientName: model.ingredientName,
            countryCode: model.countryCode,
            quantity: model.quantity ?? .grams(0),
            containerType: model.containerType,
            priority: model.priority,
            provenance: model.provenance,
            sourceNote: model.sourceNote,
            sourceDate: model.sourceDate,
            sourceVersion: model.sourceVersion,
            isEnabled: model.isEnabled,
            isPreferred: model.isPreferred
        )
        self.ingredientKey = model.ingredientKey
    }
}
