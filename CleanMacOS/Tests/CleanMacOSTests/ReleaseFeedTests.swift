import Foundation
import Testing
@testable import CleanMacOS

struct ReleaseFeedTests {
    private let feed = Data("""
    <?xml version="1.0" encoding="utf-8"?>
    <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
      <channel>
        <title>Clean macOS Updates</title>
        <item>
          <title>Version 1.0.15</title>
          <pubDate>Fri, 09 Oct 2026 11:22:21 +0700</pubDate>
          <sparkle:version>16</sparkle:version>
          <sparkle:shortVersionString>1.0.15</sparkle:shortVersionString>
          <description><![CDATA[
            <h2>What's new in 1.0.15</h2>
            <ul>
              <li><b>Faster update checks</b> — every hour &amp; more.</li>
              <li><b>Update notice</b> —
                 slides in.</li>
            </ul>
          ]]></description>
          <enclosure url="https://x/1.dmg" sparkle:edSignature="s" length="1" />
        </item>
        <item>
          <title>Version 1.0.1</title>
          <pubDate>Mon, 18 May 2026 10:00:00 +0700</pubDate>
          <sparkle:shortVersionString>1.0.1</sparkle:shortVersionString>
          <description><![CDATA[<p>First public build</p>]]></description>
        </item>
      </channel>
    </rss>
    """.utf8)

    @Test func parsesEveryReleaseNewestFirstWithBullets() throws {
        let notes = ReleaseFeed.parse(feed)
        #expect(notes.map(\.version) == ["1.0.15", "1.0.1"])
        #expect(notes[0].items == ["Faster update checks — every hour & more.", "Update notice — slides in."])
        #expect(notes[1].items == ["First public build"])
        let date = try #require(notes[0].date)
        #expect(Int(date.timeIntervalSince1970) == 1_791_519_741)
    }

    @Test func comparesVersionsNumerically() {
        #expect(ReleaseFeed.isNewer("1.0.15", than: "1.0.9"))
        #expect(!ReleaseFeed.isNewer("1.0.9", than: "1.0.15"))
        #expect(!ReleaseFeed.isNewer("1.0.15", than: "1.0.15"))
    }

    @Test func brokenFeedYieldsNoReleases() {
        #expect(ReleaseFeed.parse(Data("not xml".utf8)).isEmpty)
    }
}
