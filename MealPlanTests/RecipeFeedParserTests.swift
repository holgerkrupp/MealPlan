import Foundation
import Testing
@testable import MealPlan

struct RecipeFeedParserTests {
    private let source = URL(string: "https://example.com/feed")!

    @Test func parsesRSS2() throws {
        let xml = """
        <rss version="2.0"><channel><title>Kitchen</title><link>https://example.com</link>
        <item><guid>one</guid><title>Soup</title><link>https://example.com/soup</link>
        <description><![CDATA[<p>A warm soup.</p>]]></description>
        <pubDate>Fri, 04 Sep 2026 12:00:00 +0000</pubDate></item></channel></rss>
        """
        let feed = try RecipeFeedParser.parse(Data(xml.utf8), sourceURL: source)

        #expect(feed.title == "Kitchen")
        #expect(feed.homeURL?.absoluteString == "https://example.com")
        #expect(feed.articles.first?.id == "one")
        #expect(feed.articles.first?.title == "Soup")
        #expect(feed.articles.first?.summary == "A warm soup.")
        #expect(feed.articles.first?.publishedAt != nil)
    }

    @Test func parsesAtom() throws {
        let xml = """
        <feed xmlns="http://www.w3.org/2005/Atom"><title>Kitchen</title>
        <link rel="alternate" href="https://example.com" />
        <entry><id>tag:example,1</id><title>Cake</title>
        <link rel="alternate" href="/cake"/><author><name>Ada</name></author>
        <summary>Easy cake</summary><updated>2026-09-04T12:00:00Z</updated></entry></feed>
        """
        let feed = try RecipeFeedParser.parse(Data(xml.utf8), sourceURL: source)

        #expect(feed.articles.first?.id == "tag:example,1")
        #expect(feed.articles.first?.url.absoluteString == "https://example.com/cake")
        #expect(feed.articles.first?.author == "Ada")
    }

    @Test func parsesJSONFeed() throws {
        let json = """
        {"version":"https://jsonfeed.org/version/1.1","title":"Kitchen","home_page_url":"https://example.com",
        "items":[{"id":"one","url":"https://example.com/pasta","title":"Pasta",
        "content_html":"<p>Cook it</p>","authors":[{"name":"Sam"}],"date_published":"2026-09-04T12:00:00Z"}]}
        """
        let feed = try RecipeFeedParser.parse(Data(json.utf8), contentType: "application/feed+json", sourceURL: source)

        #expect(feed.articles.first?.title == "Pasta")
        #expect(feed.articles.first?.author == "Sam")
        #expect(feed.articles.first?.body == "<p>Cook it</p>")
    }

    @Test func discoversAdvertisedFeedsAndResolvesRelativeLinks() {
        let html = """
        <html><head>
        <link href="/rss.xml" type="application/rss+xml" rel="alternate stylesheet">
        <link rel='alternate' type='application/feed+json' href='feeds/main.json'>
        </head></html>
        """
        let urls = RecipeFeedDiscovery.feedURLs(inHTML: html, baseURL: URL(string: "https://example.com/blog/")!)

        #expect(urls.map(\.absoluteString) == [
            "https://example.com/rss.xml",
            "https://example.com/blog/feeds/main.json"
        ])
    }

    @Test func failureBackoffIsExponentialAndCapped() {
        let now = Date(timeIntervalSince1970: 1_000)
        #expect(RecipeFeedRefreshPolicy.retryDate(after: 1, now: now) == now.addingTimeInterval(3_600))
        #expect(RecipeFeedRefreshPolicy.retryDate(after: 4, now: now) == now.addingTimeInterval(8 * 3_600))
        #expect(RecipeFeedRefreshPolicy.retryDate(after: 20, now: now) == now.addingTimeInterval(48 * 3_600))
    }

    @Test func extractsReadableArticleText() {
        let html = "<html><style>bad</style><nav>menu</nav><article><h1>Soup</h1><p>Warm &amp; easy.</p></article></html>"
        let text = RecipeArticleText.extract(fromHTML: html)
        #expect(text.contains("Soup"))
        #expect(text.contains("Warm & easy."))
        #expect(!text.contains("menu"))
        #expect(!text.contains("bad"))
    }
}
