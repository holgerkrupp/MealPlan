import Testing
import Foundation
@testable import MealPlan

/// Covers the pure text-wrangling in `SocialRecipeImporter` — platform
/// detection, URL normalisation and the several ways a caption is dug out of a
/// page. The network paths and the on-device model are not exercised here.
struct SocialRecipeImporterTests {

    // MARK: - Platform detection

    @Test func recognisesTheSupportedPlatforms() {
        func platform(_ string: String) -> SocialRecipeImporter.Platform? {
            SocialRecipeImporter.platform(for: URL(string: string)!)
        }
        #expect(platform("https://www.youtube.com/watch?v=abc123") == .youTube)
        #expect(platform("https://youtu.be/abc123") == .youTube)
        #expect(platform("https://m.youtube.com/shorts/abc123") == .youTube)
        #expect(platform("https://www.instagram.com/reel/CxYz/") == .instagram)
        #expect(platform("https://www.tiktok.com/@chef/video/7300000000000000000") == .tikTok)
        #expect(platform("https://vm.tiktok.com/ZMabcdef/") == .tikTok)
        #expect(platform("https://www.pinterest.de/pin/12345/") == .pinterest)
        #expect(platform("https://pin.it/abcdef") == .pinterest)
        #expect(platform("https://www.facebook.com/watch/?v=123") == .facebook)
    }

    @Test func ignoresOrdinaryRecipeSites() {
        #expect(SocialRecipeImporter.platform(for: URL(string: "https://www.chefkoch.de/rezepte/1/x.html")!) == nil)
        #expect(SocialRecipeImporter.platform(for: URL(string: "https://cooking.nytimes.com/recipes/1")!) == nil)
    }

    // MARK: - YouTube URL normalisation

    @Test func normalisesEveryYouTubeURLShapeToWatch() {
        func watch(_ string: String) -> String? {
            SocialRecipeImporter.youTubeWatchURL(from: URL(string: string)!)?.absoluteString
        }
        #expect(watch("https://youtu.be/dQw4w9WgXcQ") == "https://www.youtube.com/watch?v=dQw4w9WgXcQ")
        #expect(watch("https://www.youtube.com/shorts/dQw4w9WgXcQ") == "https://www.youtube.com/watch?v=dQw4w9WgXcQ")
        #expect(watch("https://m.youtube.com/watch?v=dQw4w9WgXcQ&feature=share") == "https://www.youtube.com/watch?v=dQw4w9WgXcQ")
        #expect(watch("https://www.youtube.com/embed/dQw4w9WgXcQ") == "https://www.youtube.com/watch?v=dQw4w9WgXcQ")
    }

    // MARK: - Instagram

    @Test func extractsInstagramShortcode() {
        func code(_ s: String) -> String? {
            SocialRecipeImporter.instagramShortcode(from: URL(string: s)!)
        }
        #expect(code("https://www.instagram.com/p/CxAbCdEfGhI/") == "CxAbCdEfGhI")
        #expect(code("https://www.instagram.com/reel/CxAbCdEfGhI/?igshid=1") == "CxAbCdEfGhI")
        #expect(code("https://www.instagram.com/chef/") == nil)
    }

    @Test func unwrapsInstagramDescriptionToJustTheCaption() {
        let raw = #"1,234 likes, 56 comments - saltandsear on April 1, 2024: "One-pan lemon chicken. 4 thighs, 2 lemons, garlic, thyme. 200C for 35 min.""#
        let caption = SocialRecipeImporter.unwrapInstagramDescription(raw)
        #expect(caption == "One-pan lemon chicken. 4 thighs, 2 lemons, garlic, thyme. 200C for 35 min.")
    }

    @Test func instagramDescriptionWithoutTheLikePrefixIsKeptWhole() {
        let raw = "A quick weeknight dal with red lentils and spinach."
        #expect(SocialRecipeImporter.unwrapInstagramDescription(raw) == raw)
        #expect(SocialRecipeImporter.unwrapInstagramDescription(nil) == nil)
    }

    @Test func readsCaptionFromInstagramEmbedJSON() {
        let html = #"""
        <html><body><script>
        window.__additionalDataLoaded('/p/x/', {"graphql":{"shortcode_media":{
        "edge_media_to_caption":{"edges":[{"node":{"text":"Miso butter corn\n\n- 3 ears corn\n- 2 tbsp miso\n- 2 tbsp butter\nGrill 10 min, toss."}}]}}}});
        </script></body></html>
        """#
        var post = SocialPost(canonicalURL: URL(string: "https://www.instagram.com/p/x/")!)
        SocialRecipeImporter.harvestInstagramEmbed(html, into: &post)
        #expect(post.caption?.contains("Miso butter corn") == true)
        #expect(post.caption?.contains("3 ears corn") == true)
    }

    // MARK: - Meta tags

    @Test func readsOpenGraphTagsInEitherAttributeOrder() {
        let html = """
        <meta property="og:title" content="Best Carbonara">
        <meta content="Guanciale, eggs, pecorino, pepper." name="og:description">
        <meta name="twitter:image" content="https://img.example/carb.jpg">
        """
        #expect(SocialRecipeImporter.metaContent(["og:title"], in: html) == "Best Carbonara")
        #expect(SocialRecipeImporter.metaContent(["og:description"], in: html) == "Guanciale, eggs, pecorino, pepper.")
        #expect(SocialRecipeImporter.metaContent(["og:image", "twitter:image"], in: html) == "https://img.example/carb.jpg")
    }

    // MARK: - Brace-balanced JSON extraction

    @Test func pullsBalancedJSONObjectOutOfInlineScript() {
        let js = #"var ytInitialPlayerResponse = {"videoDetails":{"title":"Tacos","shortDescription":"Recipe: {see below}","author":"Chef"}};var x=1;"#
        let object = SocialRecipeImporter.jsonObject(afterKey: "ytInitialPlayerResponse", in: js)
        #expect(object != nil)
        let decoded = try? JSONSerialization.jsonObject(with: Data(object!.utf8)) as? [String: Any]
        let details = decoded?["videoDetails"] as? [String: Any]
        #expect(details?["title"] as? String == "Tacos")
        #expect(details?["shortDescription"] as? String == "Recipe: {see below}")
    }

    @Test func braceInsideStringDoesNotEndTheObject() {
        let js = #"ytInitialPlayerResponse: {"a":"}}}}","b":{"c":1}}"#
        let object = SocialRecipeImporter.jsonObject(afterKey: "ytInitialPlayerResponse", in: js)
        #expect(object == #"{"a":"}}}}","b":{"c":1}}"#)
    }

    // MARK: - Caption track selection

    @Test func prefersAManualTrackInTheDeviceLanguageThenFallsBack() {
        let tracks: [[String: Any]] = [
            ["languageCode": "fr", "kind": "asr", "baseUrl": "fr-asr"],
            ["languageCode": "en", "kind": "asr", "baseUrl": "en-asr"],
            ["languageCode": "en", "baseUrl": "en-manual"],
        ]
        let chosen = SocialRecipeImporter.preferredCaptionTrack(tracks)
        // Test host locale is en_US, so the manual English track wins.
        #expect(chosen?["baseUrl"] as? String == "en-manual")

        let asrOnly: [[String: Any]] = [["languageCode": "de", "kind": "asr", "baseUrl": "de-asr"]]
        #expect(SocialRecipeImporter.preferredCaptionTrack(asrOnly)?["baseUrl"] as? String == "de-asr")
    }

    // MARK: - Pinterest outbound link

    @Test func findsThePinsOutboundRecipeLink() {
        let html = #"{"pin":{"link":"https:\/\/smittenkitchen.com\/2024\/01\/best-brownies\/","title":"Brownies"}}"#
        let url = SocialRecipeImporter.pinterestOutboundURL(in: html)
        #expect(url?.absoluteString == "https://smittenkitchen.com/2024/01/best-brownies/")
    }

    @Test func ignoresOutboundLinksBackIntoPinterest() {
        let html = #"{"link":"https://www.pinterest.com/pin/999/"}"#
        #expect(SocialRecipeImporter.pinterestOutboundURL(in: html) == nil)
    }

    // MARK: - Title cleanup

    @Test func trimsChannelAndHypeOffVideoTitles() {
        #expect(SocialRecipeImporter.cleanTitle("Creamy Tuscan Chicken | Kitchen Stories") == "Creamy Tuscan Chicken")
        #expect(SocialRecipeImporter.cleanTitle("15-Minute Pad Thai – so easy!") == "15-Minute Pad Thai")
        #expect(SocialRecipeImporter.cleanTitle("Plain Title") == "Plain Title")
    }
}
