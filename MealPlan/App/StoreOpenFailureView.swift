import SwiftUI

/// Shown instead of the app when the on-device store won't open. Nothing has
/// been changed at that point, and this screen doesn't change anything either.
struct StoreOpenFailureView: View {
    let failure: Error

    var body: some View {
        ContentUnavailableView {
            Label(String(localized: "MealPlan can’t open its data"), systemImage: "exclamationmark.triangle")
        } description: {
            VStack(spacing: 12) {
                Text("Your data has not been changed. Check for an app update and restart your device. If this keeps happening, contact support with the details below.")
                Text(failure.localizedDescription)
                    .font(.footnote)
                    .textSelection(.enabled)
            }
        }
    }
}
