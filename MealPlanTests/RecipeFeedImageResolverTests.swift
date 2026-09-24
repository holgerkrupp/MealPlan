import Foundation
import Testing
@testable import MealPlan

/// The pure half of the fallback that looks for a photo on an article's own
/// page when its feed carried none.
struct RecipeFeedImageResolverTests {
    private let page = URL(string: "https://example.com/recipes/soup")!

    actor LoaderProbe {
        var calls = 0
        var active = 0
        var maximum = 0
        var result: ArticleImageLookup = .found(URL(string: "https://example.com/soup.jpg")!)

        func load() async -> ArticleImageLookup {
            calls += 1
            active += 1
            maximum = max(maximum, active)
            try? await Task.sleep(for: .milliseconds(20))
            active -= 1
            return result
        }

        func stats() -> (calls: Int, maximum: Int) { (calls, maximum) }
    }

    @Test func boundedLookupConcurrency() async {
        let probe = LoaderProbe()
        let resolver = RecipeFeedImageResolver(concurrencyLimit: 2) { _ in await probe.load() }
        await withTaskGroup(of: ArticleImageLookup.self) { group in
            for index in 0..<8 {
                group.addTask {
                    await resolver.lookUpImage(forArticleAt: URL(string: "https://example.com/\(index)")!)
                }
            }
        }
        #expect(await probe.stats().maximum <= 2)
    }

    @Test func duplicateURLRequestsCoalesce() async {
        let probe = LoaderProbe()
        let resolver = RecipeFeedImageResolver(concurrencyLimit: 2) { _ in await probe.load() }
        let url = URL(string: "https://example.com/same")!
        async let first = resolver.lookUpImage(forArticleAt: url)
        async let second = resolver.lookUpImage(forArticleAt: url)
        _ = await (first, second)
        #expect(await probe.stats().calls == 1)
    }

    @Test func noneIsRememberedForTheSession() async {
        let probe = LoaderProbe()
        await probe.setResult(.none)
        let resolver = RecipeFeedImageResolver { _ in await probe.load() }
        let url = URL(string: "https://example.com/no-image")!
        #expect(await resolver.lookUpImage(forArticleAt: url) == .none)
        #expect(await resolver.lookUpImage(forArticleAt: url) == .none)
        #expect(await probe.stats().calls == 1)
    }

    @Test func cancellationDoesNotStartQueuedLookup() async {
        let probe = LoaderProbe()
        let resolver = RecipeFeedImageResolver(concurrencyLimit: 1) { _ in await probe.load() }
        let first = Task {
            await resolver.lookUpImage(forArticleAt: URL(string: "https://example.com/slow")!)
        }
        try? await Task.sleep(for: .milliseconds(5))
        let second = Task {
            await resolver.lookUpImage(forArticleAt: URL(string: "https://example.com/cancelled")!)
        }
        second.cancel()
        #expect(await second.value == .unreachable)
        _ = await first.value
        #expect(await probe.stats().calls == 1)
    }

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

private extension RecipeFeedImageResolverTests.LoaderProbe {
    func setResult(_ value: ArticleImageLookup) { result = value }
}
