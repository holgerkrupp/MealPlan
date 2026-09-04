import SwiftUI
import StoreKit

/// One-time unlock for planning beyond the free seven-day horizon.
@MainActor
struct PaywallView: View {
    @Environment(PurchaseManager.self) private var purchaseManager
    @Environment(\.dismiss) private var dismiss

    var onUnlocked: () -> Void = {}

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    Image(systemName: "calendar.badge.plus")
                        .font(.system(size: 52))
                        .foregroundStyle(.tint)
                        .symbolRenderingMode(.hierarchical)

                    VStack(spacing: 8) {
                        Text(String(localized: "Plan without limits"))
                            .font(.title.bold())
                        Text(String(localized: "Plan the next 7 days for free, or unlock MealPlan to plan as far ahead as you like."))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }

                    VStack(alignment: .leading, spacing: 16) {
                        feature("infinity", String(localized: "Unlimited planning"), String(localized: "Fill your calendar weeks, months, or years ahead."))
                        feature("repeat", String(localized: "Room for every routine"), String(localized: "Let regular meals keep your future plan filled."))
                        feature("checkmark.seal", String(localized: "One-time purchase"), String(localized: "No subscription and no recurring charge."))
                    }
                    .frame(maxWidth: 380)

                    if let error = purchaseManager.lastError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 380)
                    }

                    VStack(spacing: 10) {
                        Button {
                            Task {
                                if await purchaseManager.purchase() {
                                    dismiss()
                                    onUnlocked()
                                }
                            }
                        } label: {
                            Group {
                                if purchaseManager.purchaseInFlight {
                                    ProgressView().controlSize(.small)
                                } else if let product = purchaseManager.product {
                                    Text(String(localized: "Unlock App for \(product.displayPrice)"))
                                } else {
                                    Text(String(localized: "Unlock App"))
                                }
                            }
                            .frame(maxWidth: 300)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(purchaseManager.purchaseInFlight)

                        Button(String(localized: "Restore Purchases")) {
                            Task {
                                await purchaseManager.restorePurchases()
                                if purchaseManager.isUnlocked {
                                    dismiss()
                                    onUnlocked()
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tint)
                        .disabled(purchaseManager.purchaseInFlight)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(28)
            }
            .navigationTitle(String(localized: "Unlock App"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Not Now")) { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(width: 480, height: 590)
        #else
        .presentationDetents([.large])
        #endif
        .task {
            if purchaseManager.product == nil { await purchaseManager.loadProduct() }
        }
    }

    private func feature(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.semibold)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

#Preview {
    PaywallView()
        .environment(PurchaseManager.shared)
}
