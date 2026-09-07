import Foundation
import Testing
@testable import MealPlan

/// The pure half of the fallback that looks for a photo on an article's own
/// page when its feed carried none.
struct RecipeFeedImageResolverTests {
    private let page = URL(string: "https://example.com/recipes/soup")!

    @Test func readsTheSocialPreviewImage() {
        let html = """
        <html><head><meta property="og:image" content="https://example.com/soup.jpg"></head></html>
        """
        #expect(
            RecipeFeedImageResolver.imageURL(inHTML: html, relativeTo: page)?.absoluteString
                == "https://example.com/soup.jpg"
        )
    }

    @Test func prefersTheRecipesOwnImageOverThePreview() {
        // A site's og:image is often its logo, so structured recipe data wins.
        let html = """
        <html><head>
        <meta property="og:image" content="https://example.com/logo.png">
        <script type="application/ld+json">
        {"@context":"https://schema.org","@type":"Recipe","name":"Soup",
         "image":"https://example.com/the-actual-soup.jpg",
         "recipeIngredient":["water"],"recipeInstructions":"Boil it."}
        </script>
        </head></html>
        """
        #expect(
            RecipeFeedImageResolver.imageURL(inHTML: html, relativeTo: page)?.absoluteString
                == "https://example.com/the-actual-soup.jpg"
        )
    }

    @Test func fallsBackToTwitterAndImageSrc() {
        let twitter = """
        <html><head><meta name="twitter:image" content="/photos/soup.jpg"></head></html>
        """
        #expect(
            RecipeFeedImageResolver.imageURL(inHTML: twitter, relativeTo: page)?.absoluteString
                == "https://example.com/photos/soup.jpg"
        )

        let linkRel = """
        <html><head><link rel="image_src" href="https://cdn.example.com/soup.jpg"></head></html>
        """
        #expect(
            RecipeFeedImageResolver.imageURL(inHTML: linkRel, relativeTo: page)?.absoluteString
                == "https://cdn.example.com/soup.jpg"
        )
    }

    @Test func resolvesRelativeAddressesAgainstTheArticle() {
        let html = """
        <html><head><meta property="og:image" content="../images/soup.jpg"></head></html>
        """
        #expect(
            RecipeFeedImageResolver.imageURL(inHTML: html, relativeTo: page)?.absoluteString
                == "https://example.com/images/soup.jpg"
        )
    }

    @Test func rejectsNonHTTPSources() {
        let html = """
        <html><head><meta property="og:image" content="data:image/gif;base64,R0lGOD"></head></html>
        """
        #expect(RecipeFeedImageResolver.imageURL(inHTML: html, relativeTo: page) == nil)
    }

    @Test func returnsNothingWhenThePageAdvertisesNoPicture() {
        let html = "<html><head><title>Soup</title></head><body><p>Boil it.</p></body></html>"
        #expect(RecipeFeedImageResolver.imageURL(inHTML: html, relativeTo: page) == nil)
    }
}
