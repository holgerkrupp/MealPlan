#if os(iOS)
import SwiftUI
import UIKit

/// One of the app icons available in Settings.
@MainActor
private enum AppIconOption: String, CaseIterable, Identifiable, Hashable {
    case pumpkin = "Pumpkin"
    case classic = "AppIcon"

    var id: String { rawValue }

    /// `nil` tells UIKit to restore the primary icon.
    var alternateIconName: String? {
        self == .pumpkin ? nil : rawValue
    }

    var localizedName: String {
        switch self {
        case .pumpkin:
            String(localized: "Pumpkin")
        case .classic:
            String(localized: "Classic")
        }
    }

    /// Flat artwork from Assets.xcassets. The compiled `.icon` assets are
    /// multi-size icon stacks and are not suitable for displaying in SwiftUI.
    var previewAssetName: String {
        "IconPreview/\(rawValue)"
    }

    var hasPreviewAsset: Bool {
        UIImage(named: previewAssetName) != nil
    }

    static var current: Self {
        let currentName = UIApplication.shared.alternateIconName ?? Self.pumpkin.rawValue
        return Self(rawValue: currentName) ?? .pumpkin
    }
}

/// The Settings row that opens the visual app-icon overview.
@MainActor
struct AppIconSettingsSection: View {
    @State private var selectedIcon = AppIconOption.current
    @State private var errorMessage: String?

    var body: some View {
        if UIApplication.shared.supportsAlternateIcons {
            Section {
                NavigationLink {
                    AppIconOverviewView(
                        selectedIcon: $selectedIcon,
                        errorMessage: $errorMessage
                    )
                } label: {
                    HStack(spacing: 12) {
                        AppIconTile(icon: selectedIcon, isSelected: false, size: 44)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(String(localized: "App Icon"))
                            Text(selectedIcon.localizedName)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text(String(localized: "Appearance"))
            } footer: {
                Text(String(localized: "Choose the icon MealPlan uses on your Home Screen and in search."))
            }
        }
    }
}

/// A visual overview of all app icons, modeled after Moves' icon picker.
@MainActor
private struct AppIconOverviewView: View {
    @Environment(\.dismiss) private var dismiss

    @Binding var selectedIcon: AppIconOption
    @Binding var errorMessage: String?

    private let columns = [GridItem(.adaptive(minimum: 88, maximum: 132), spacing: 18)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 20) {
                ForEach(AppIconOption.allCases) { icon in
                    Button {
                        select(icon)
                    } label: {
                        VStack(spacing: 8) {
                            AppIconTile(icon: icon, isSelected: icon == selectedIcon)

                            Text(icon.localizedName)
                                .font(.subheadline.weight(icon == selectedIcon ? .semibold : .regular))
                                .foregroundStyle(.primary)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(icon.localizedName)
                    .accessibilityAddTraits(icon == selectedIcon ? [.isButton, .isSelected] : [.isButton])
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 24)
        }
        .navigationTitle(String(localized: "App Icon"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(String(localized: "Done")) {
                    dismiss()
                }
            }
        }
        .alert(
            String(localized: "Couldn’t change app icon"),
            isPresented: errorIsPresented,
            actions: {
                Button(String(localized: "OK"), role: .cancel) { errorMessage = nil }
            },
            message: {
                Text(errorMessage ?? String(localized: "Please try again."))
            }
        )
    }

    private var errorIsPresented: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { isPresented in
                if !isPresented { errorMessage = nil }
            }
        )
    }

    private func select(_ icon: AppIconOption) {
        guard icon != selectedIcon else { return }

        let previous = selectedIcon
        selectedIcon = icon

        UIApplication.shared.setAlternateIconName(icon.alternateIconName) { error in
            guard let error else { return }
            Task { @MainActor in
                selectedIcon = previous
                errorMessage = error.localizedDescription
            }
        }
    }
}

/// Displays a flat icon preview with the same rounded shape used by iOS.
@MainActor
private struct AppIconTile: View {
    let icon: AppIconOption
    let isSelected: Bool
    var size: CGFloat = 76

    private var cornerRadius: CGFloat { size * 0.2237 }

    var body: some View {
        artwork
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.separator),
                        lineWidth: isSelected ? 3 : 1
                    )
            }
            .overlay(alignment: .topTrailing) {
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color.accentColor)
                        .background(Color.white, in: Circle())
                        .clipShape(Circle())
                        .offset(x: 5, y: -5)
                }
            }
            .padding(4)
            .contentShape(Rectangle())
    }

    @ViewBuilder
    private var artwork: some View {
        if icon.hasPreviewAsset {
            Image(icon.previewAssetName)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fill)
        } else {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.quaternary)
                .overlay {
                    Image(systemName: "app.dashed")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
        }
    }
}
#endif
