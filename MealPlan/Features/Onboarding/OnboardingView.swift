import SwiftUI

enum OnboardingPreferenceKeys {
    static let didCompleteOnboarding = "didCompleteOnboarding"
}

/// First-run tour. Explains the week plan, the dish library, and — the part
/// people miss most often — that recipes can be shared into MealPlan from
/// Safari, other recipe apps, and recipe files.
struct OnboardingView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selectedPage = 0

    private var pages: [OnboardingPage] {
        [
            OnboardingPage(
                title: String(localized: "Welcome to MealPlan"),
                summary: String(localized: "MealPlan keeps your family’s week of meals, the dishes you cook, and the shopping that follows in one place."),
                systemImage: "fork.knife.circle.fill",
                tint: .accentColor,
                bullets: [
                    String(localized: "Plan the week meal by meal on a calendar the whole family sees."),
                    String(localized: "Collect the dishes your family likes, with recipes, photos, and tags."),
                    String(localized: "Turn the planned week into a shopping list without writing it twice.")
                ]
            ),
            OnboardingPage(
                title: String(localized: "Plan the week"),
                summary: String(localized: "The plan shows one card per meal per day. Fill the cards you care about and leave the rest empty."),
                systemImage: "calendar",
                tint: .blue,
                bullets: [
                    String(localized: "Tap a meal to pick a dish, or drag a dish over from the list beside the plan."),
                    String(localized: "Set up regular meals like Taco Tuesday — they plan themselves weeks ahead."),
                    String(localized: "Save a good week as a template and reuse it when you run out of ideas."),
                    String(localized: "Rename, add, or reorder your meals in Settings.")
                ]
            ),
            OnboardingPage(
                title: String(localized: "Your dishes"),
                summary: String(localized: "Dishes are the heart of the app: everything you plan, cook, and shop for comes from your library."),
                systemImage: "fork.knife",
                tint: .orange,
                bullets: [
                    String(localized: "A name is enough to add a dish — recipe, photo, and ingredients can follow later."),
                    String(localized: "Tag dishes as vegetarian, quick, or a kids’ favorite, then filter the library by it."),
                    String(localized: "Cooking mode walks you through the steps and scales ingredients to the servings you cook.")
                ]
            ),
            sharingPage,
            OnboardingPage(
                title: String(localized: "Shopping list"),
                summary: String(localized: "The shopping list is built from the days you plan to cook, so it matches what is actually on the calendar."),
                systemImage: "cart",
                tint: .teal,
                bullets: [
                    String(localized: "Choose a date range and rebuild the list; the same ingredient from several dishes is added up."),
                    String(localized: "Items are sorted by aisle, and you can rename an aisle so it matches your shop."),
                    String(localized: "Mark pantry staples in Settings to keep things you always have at home off the list."),
                    String(localized: "Share the list or send it to Reminders.")
                ]
            ),
            OnboardingPage(
                title: String(localized: "Cook together"),
                summary: String(localized: "MealPlan is made for a household, not just one cook. Everything is stored on your device and shared through iCloud."),
                systemImage: "person.2.fill",
                tint: .indigo,
                bullets: [
                    String(localized: "Invite your family from the Household section — everyone sees the same plan and dishes."),
                    String(localized: "Invite people as editors, or as view-only guests who can look but not change."),
                    String(localized: "Widgets and Siri show tonight’s meal without opening the app."),
                    String(localized: "Open Settings any time to revisit this guide.")
                ]
            )
        ]
    }

    /// Sharing a recipe page is the fastest way into the library, so it gets a
    /// page of its own. The share extension is iPhone/iPad only, so the Mac
    /// gets the routes that exist there.
    private var sharingPage: OnboardingPage {
        #if os(iOS)
        OnboardingPage(
            title: String(localized: "Share recipes into MealPlan"),
            summary: String(localized: "Found a recipe on a website, in another recipe app, or in a message? Share it to MealPlan instead of typing it in again."),
            systemImage: "square.and.arrow.up",
            tint: .green,
            bullets: [
                String(localized: "In Safari or any other app, tap Share and choose MealPlan — ingredients, steps, and the photo come along when the page offers them."),
                String(localized: "While sharing you can put the new dish straight onto a day in your plan."),
                String(localized: "Share or open a .paprikarecipes or .mealplanrecipes file to bring a whole recipe collection over at once."),
                String(localized: "No share sheet? Open a dish and use “Find a recipe” to fetch it from a website, or scan a cookbook page or PDF.")
            ]
        )
        #else
        OnboardingPage(
            title: String(localized: "Bring recipes in"),
            summary: String(localized: "Recipes rarely start in MealPlan. Bring them in from the web, from other recipe apps, and from your iPhone."),
            systemImage: "square.and.arrow.down",
            tint: .green,
            bullets: [
                String(localized: "On iPhone and iPad, share a recipe page from Safari or another app straight to MealPlan — it appears here through iCloud."),
                String(localized: "Open a .paprikarecipes or .mealplanrecipes file to bring a whole recipe collection over at once."),
                String(localized: "Open a dish and use “Find a recipe” to fetch ingredients and steps from a website."),
                String(localized: "Export your recipes any time to hand them to someone else or keep a backup.")
            ]
        )
        #endif
    }

    var body: some View {
        NavigationStack {
            TabView(selection: $selectedPage) {
                ForEach(Array(pages.enumerated()), id: \.element.id) { index, page in
                    OnboardingPageView(page: page)
                        .tag(index)
                }
            }
            #if os(iOS)
            .tabViewStyle(.page(indexDisplayMode: .automatic))
            .indexViewStyle(.page(backgroundDisplayMode: .interactive))
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .navigationTitle(String(localized: "Getting started"))
            .safeAreaInset(edge: .bottom) {
                Button {
                    if selectedPage < pages.count - 1 {
                        withAnimation { selectedPage += 1 }
                    } else {
                        dismiss()
                    }
                } label: {
                    Label(primaryButtonTitle, systemImage: primaryButtonImage)
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal)
                .padding(.top, 12)
                .padding(.bottom, 8)
                .background(.thinMaterial)
            }
            #if os(macOS)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Skip")) { dismiss() }
                }
            }
            .frame(minWidth: 460, minHeight: 560)
            #endif
        }
    }

    private var primaryButtonTitle: String {
        selectedPage == pages.count - 1
            ? String(localized: "Start planning")
            : String(localized: "Continue")
    }

    private var primaryButtonImage: String {
        selectedPage == pages.count - 1 ? "checkmark.circle.fill" : "arrow.right.circle.fill"
    }
}

private struct OnboardingPage: Identifiable {
    let id = UUID()
    let title: String
    let summary: String
    let systemImage: String
    let tint: Color
    let bullets: [String]
}

private struct OnboardingPageView: View {
    let page: OnboardingPage

    var body: some View {
        ScrollView {
            VStack(spacing: 26) {
                Image(systemName: page.systemImage)
                    .font(.system(size: 76, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(page.tint)
                    .frame(width: 120, height: 120)
                    .background(page.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
                    .padding(.top, 34)

                VStack(spacing: 10) {
                    Text(page.title)
                        .font(.largeTitle.bold())
                        .multilineTextAlignment(.center)

                    Text(page.summary)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 14) {
                    ForEach(page.bullets, id: \.self) { bullet in
                        Label {
                            Text(bullet)
                                .font(.body)
                                .fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(page.tint)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(18)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                Spacer(minLength: 100)
            }
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
        }
    }
}

#Preview {
    OnboardingView()
}

#Preview("One page") {
    OnboardingPageView(page: OnboardingPage(
        title: String(localized: "Plan the week"),
        summary: String(localized: "The plan shows one card per meal per day. Fill the cards you care about and leave the rest empty."),
        systemImage: "calendar",
        tint: .blue,
        bullets: [
            String(localized: "Drag a dish from the library onto any card."),
            String(localized: "Rename, add, or reorder your meals in Settings.")
        ]
    ))
}
