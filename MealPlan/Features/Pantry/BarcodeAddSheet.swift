import SwiftUI
import SwiftData

#if os(iOS)
@preconcurrency import VisionKit
import Vision
#endif

/// Whether this device can scan barcodes live. Only iPhone and iPad with a
/// camera that VisionKit's data scanner supports; never the Mac.
@MainActor
enum BarcodeScanAvailability {
    static var isAvailable: Bool {
        #if os(iOS)
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable
        #else
        false
        #endif
    }
}

/// Scan a product's barcode, then put it on the shopping list or in the
/// pantry.
///
/// There is no product database: a code is resolved only against names this
/// device remembered from earlier scans (`BarcodeProductMemory`). An unknown
/// code — or no scan at all — just leaves the name field empty to type into,
/// so the sheet always works as a fast manual add.
@MainActor
struct BarcodeAddSheet: View {
    enum Destination { case shoppingList, pantry }

    var defaultDestination: Destination
    var location: InventoryStorageLocation? = nil

    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var code: String?
    @State private var name = ""
    @State private var addedMessage: String?
    @FocusState private var nameFocused: Bool

    private let memory = BarcodeProductMemory()

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                #if os(iOS)
                if code == nil, BarcodeScanAvailability.isAvailable {
                    BarcodeScannerView { scanned in handleScan(scanned) }
                        .ignoresSafeArea(edges: .bottom)
                        .overlay(alignment: .bottom) {
                            Text("Point the camera at a barcode")
                                .font(.callout)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(.regularMaterial, in: .capsule)
                                .padding()
                        }
                        .frame(maxHeight: 320)
                }
                #endif
                form
            }
            .navigationTitle(String(localized: "Scan a product"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Done")) { dismiss() }
                }
            }
        }
    }

    private var form: some View {
        Form {
            Section {
                TextField(String(localized: "Product name"), text: $name)
                    .focused($nameFocused)
                    .submitLabel(.done)
                    .onSubmit { add(to: defaultDestination) }
                if let code {
                    LabeledContent(String(localized: "Barcode"), value: code)
                    Button(String(localized: "Scan another")) {
                        self.code = nil
                        name = ""
                        addedMessage = nil
                    }
                }
            } footer: {
                if code != nil, memory.name(for: code ?? "") == nil {
                    Text("A new barcode. Name it once — this device remembers the name for the next scan.")
                } else if code == nil {
                    Text("Or type the name yourself.")
                }
            }

            Section {
                Button {
                    add(to: .shoppingList)
                } label: {
                    Label(String(localized: "Add to shopping list"), systemImage: "cart.badge.plus")
                }
                Button {
                    add(to: .pantry)
                } label: {
                    Label(String(localized: "Add to the pantry"), systemImage: "cabinet")
                }
            }
            .disabled(trimmedName.isEmpty)

            if let addedMessage {
                Section {
                    Label(addedMessage, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func handleScan(_ scanned: String) {
        guard code == nil else { return }
        code = scanned
        addedMessage = nil
        name = memory.name(for: scanned) ?? ""
        if name.isEmpty { nameFocused = true }
    }

    private func add(to destination: Destination) {
        guard let household = appState.currentHousehold, !trimmedName.isEmpty else { return }
        let productName = trimmedName
        switch destination {
        case .shoppingList:
            guard ShoppingListBuilder.addManualItem(
                named: productName,
                household: household,
                system: appState.unitSystem,
                roundsAmounts: appState.roundsDisplayedAmounts,
                context: context
            ) != nil else { return }
            addedMessage = String(localized: "Added “\(productName)” to the shopping list.")
        case .pantry:
            guard PantryActions.startTracking(
                named: productName,
                location: location,
                household: household,
                context: context
            ) != nil else { return }
            addedMessage = String(localized: "Added “\(productName)” to the pantry.")
        }
        if let code { memory.remember(productName, for: code) }
        // The product stays shown, so it can go to the other destination too;
        // "Scan another" starts over. Restarting the camera here would only
        // read the same code again while it's still in view.
        if code == nil { name = "" }
    }
}

#if os(iOS)
/// VisionKit's live data scanner, set to read retail barcodes only.
@MainActor
private struct BarcodeScannerView: UIViewControllerRepresentable {
    var onScan: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let controller = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.ean13, .ean8, .upce])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isHighlightingEnabled: true
        )
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {
        context.coordinator.onScan = onScan
        if !controller.isScanning {
            try? controller.startScanning()
        }
    }

    static func dismantleUIViewController(_ controller: DataScannerViewController, coordinator: Coordinator) {
        controller.stopScanning()
    }

    func makeCoordinator() -> Coordinator { Coordinator(onScan: onScan) }

    @MainActor
    final class Coordinator: NSObject, @MainActor DataScannerViewControllerDelegate {
        var onScan: (String) -> Void
        init(onScan: @escaping (String) -> Void) { self.onScan = onScan }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            didAdd addedItems: [RecognizedItem],
            allItems: [RecognizedItem]
        ) {
            for item in addedItems {
                if case .barcode(let barcode) = item,
                   let payload = barcode.payloadStringValue,
                   !BarcodeProductMemory.normalize(payload).isEmpty {
                    onScan(payload)
                    return
                }
            }
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didTapOn item: RecognizedItem) {
            if case .barcode(let barcode) = item, let payload = barcode.payloadStringValue {
                onScan(payload)
            }
        }
    }
}
#endif
