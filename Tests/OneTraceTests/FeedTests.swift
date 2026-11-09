import Foundation
import XCTest
@testable import OneTrace

final class FeedTests: XCTestCase {
    private var transport: FakeTransport!
    private var storage: Storage!

    private static let twoCards = #"""
    {"data": [
        {"token": "t1", "layout": "classic", "title": "Free delivery", "body": "Until Sunday", "image_url": "https://cdn.example.com/a.jpg",
         "button_text": "Shop now", "button_url": "https://shop.example.com/sale", "pinned": true, "read": false,
         "created_at": "2026-11-09T10:00:00+00:00", "expires_at": "2026-11-23T10:00:00+00:00"},
        {"token": "t2", "layout": "captioned", "title": "New collection", "button_url": "shopapp://catalog/new", "pinned": false, "read": false,
         "created_at": "2026-11-08T09:30:00+00:00", "expires_at": "2026-11-22T09:30:00+00:00"}
    ], "unread": 2}
    """#

    override func setUp() {
        transport = FakeTransport()
        storage = Storage(defaults: UserDefaults(suiteName: "onetrace-tests-\(UUID().uuidString)")!)
    }

    private func client(trackLifecycle: Bool = false) -> Client {
        Client(
            config: OneTraceConfig(writeKey: "cdp_wk_test", host: "https://crm.example.com", flushAt: 100, flushInterval: 3600, trackLifecycle: trackLifecycle),
            storage: storage,
            events: EventQueue(file: FileManager.default.temporaryDirectory.appendingPathComponent("onetrace-\(UUID().uuidString).jsonl"), maxSize: 50),
            transport: transport,
            device: DeviceContext(installationId: storage.installationId),
            deliver: { $0() }
        )
    }

    private func drain(_ client: Client) {
        client.queue.sync {}
    }

    private func card(_ json: [String: Any]) -> OneTraceFeedCard? {
        OneTraceFeedCard(json: json)
    }

    func testParsesCardsOfTheThreeLayouts() {
        let classic = card(["token": "t1", "layout": "classic", "title": "Free delivery", "body": "Until Sunday", "image_url": "https://cdn.example.com/a.jpg",
                            "button_text": "Shop now", "button_url": "https://shop.example.com/sale", "pinned": true, "read": true,
                            "created_at": "2026-11-09T10:00:00+00:00", "expires_at": "2026-11-23T10:00:00.000Z"])!
        XCTAssertEqual(classic.layout, .classic)
        XCTAssertEqual(classic.body, "Until Sunday")
        XCTAssertEqual(classic.imageURL?.absoluteString, "https://cdn.example.com/a.jpg")
        XCTAssertEqual(classic.buttonURL?.absoluteString, "https://shop.example.com/sale")
        XCTAssertTrue(classic.pinned)
        XCTAssertTrue(classic.read)
        XCTAssertFalse(classic.opensOnTap)
        XCTAssertEqual(classic.createdAt, Date(timeIntervalSince1970: 1_794_218_400))
        XCTAssertEqual(classic.expiresAt, Date(timeIntervalSince1970: 1_795_428_000))

        // Without a button label the whole card is the link; a banner is always.
        let captioned = card(["token": "t2", "layout": "captioned", "title": "New", "button_url": "shopapp://catalog/new", "button_text": " "])!
        XCTAssertNil(captioned.buttonText)
        XCTAssertTrue(captioned.opensOnTap)
        XCTAssertTrue(card(["token": "t3", "layout": "banner", "button_text": "Go", "button_url": "https://shop.example.com"])!.opensOnTap)

        // An unknown layout falls back to classic; a card without a token is skipped.
        XCTAssertEqual(card(["token": "t4", "layout": "carousel", "title": "?"])?.layout, .classic)
        XCTAssertNil(card(["title": "No token"]))
    }

    func testDropsLinksThatAreNotPagesOrAppLinks() {
        let unsafe = card(["token": "t1", "button_url": "javascript:alert(1)", "image_url": "data:image/png;base64,AAAA"])!
        XCTAssertNil(unsafe.buttonURL)
        XCTAssertNil(unsafe.imageURL)
        XCTAssertFalse(unsafe.opensOnTap)
        XCTAssertNil(card(["token": "t2", "button_url": "/sale"])!.buttonURL)
        XCTAssertNil(card(["token": "t3", "image_url": "shopapp://image"])!.imageURL)
    }

    func testLoadsTheFeedOfTheAnonymousIdAndCountsUnreadCards() {
        transport.feed = Self.twoCards
        let client = client()
        var loaded: [OneTraceFeedCard] = []
        var unread: [Int] = []
        _ = client.observeFeedUnread { unread.append($0) }
        client.fetchFeed { loaded = $0 }
        drain(client)

        XCTAssertEqual(transport.gets.first, "/feed?anonymousId=\(storage.anonymousId)")
        XCTAssertEqual(loaded.map(\.token), ["t1", "t2"])
        XCTAssertEqual(client.feed.currentUnread, 2)
        XCTAssertEqual(client.feed.currentCards.map(\.title), ["Free delivery", "New collection"])
        // The observer gets the count at once and loads the feed itself; it fires again only on changes.
        XCTAssertEqual(unread, [0, 2])
    }

    func testReportsAShowOnceAndKeepsTheCardReadWhenTheServerHasNotRecordedIt() {
        transport.feed = Self.twoCards
        transport.feedEventStatus = 0
        let client = client()
        var unread: [Int] = []
        let observation = client.observeFeedUnread { unread.append($0) }
        drain(client)

        let first = client.feed.currentCards[0]
        client.reportFeed(first.token, "shown", nil)
        client.reportFeed(first.token, "shown", nil)
        drain(client)

        XCTAssertEqual(transport.feedEvents.count, 1)
        XCTAssertEqual(transport.feedEvents[0]["token"] as? String, "t1")
        XCTAssertEqual(transport.feedEvents[0]["event"] as? String, "shown")
        XCTAssertNil(transport.feedEvents[0]["url"])
        XCTAssertEqual(unread, [0, 2, 1])

        // The report did not reach the platform, so it still returns the card as unread.
        client.fetchFeed(nil)
        drain(client)
        XCTAssertEqual(client.feed.currentCards.map(\.read), [true, false])
        XCTAssertEqual(client.feed.currentUnread, 1)

        observation.cancel()
        client.reportFeed("t2", "shown", nil)
        drain(client)
        XCTAssertEqual(unread, [0, 2, 1])
        XCTAssertEqual(client.feed.currentUnread, 0)
    }

    func testDoesNotReportCardsAlreadyRead() {
        transport.feed = #"{"data": [{"token": "t1", "title": "Seen", "read": true}], "unread": 0}"#
        let client = client()
        client.fetchFeed(nil)
        client.reportFeed("t1", "shown", nil)
        drain(client)

        XCTAssertTrue(transport.feedEvents.isEmpty)
    }

    func testReportsClicksWithTheLinkAndDismissals() {
        transport.feed = Self.twoCards
        let client = client()
        var lists: [[String]] = []
        _ = client.observeFeed { lists.append($0.map(\.token)) }
        client.fetchFeed(nil)
        drain(client)

        client.reportFeed("t2", "clicked", "shopapp://catalog/new")
        client.reportFeed("t1", "dismissed", nil)
        drain(client)

        XCTAssertEqual(transport.feedEvents.map { $0["event"] as? String }, ["clicked", "dismissed"])
        XCTAssertEqual(transport.feedEvents[0]["url"] as? String, "shopapp://catalog/new")
        XCTAssertEqual(client.feed.currentCards.map(\.token), ["t2"])
        XCTAssertEqual(client.feed.currentUnread, 0)
        XCTAssertEqual(lists.first, [])
        XCTAssertEqual(lists.last, ["t2"])

        // A dismissal the platform has not recorded yet does not bring the card back.
        client.fetchFeed(nil)
        drain(client)
        XCTAssertEqual(client.feed.currentCards.map(\.token), ["t2"])
    }

    func testKeepsTheCardsOnANetworkError() {
        transport.feed = Self.twoCards
        let client = client()
        client.fetchFeed(nil)
        drain(client)

        transport.feedStatus = 0
        var loaded: [OneTraceFeedCard] = []
        client.fetchFeed { loaded = $0 }
        drain(client)
        XCTAssertEqual(loaded.map(\.token), ["t1", "t2"])
    }

    func testRefreshesTheFeedOnAppOpenAndResetOnlyOnceTheAppUsesIt() {
        transport.feed = Self.twoCards
        let client = client()
        client.appForeground(fromBackground: true)
        drain(client)
        XCTAssertFalse(transport.gets.contains { $0.hasPrefix("/feed") })

        client.fetchFeed(nil)
        client.appForeground(fromBackground: true)
        drain(client)
        XCTAssertEqual(transport.gets.filter { $0.hasPrefix("/feed") }.count, 2)

        // A sign-out: the next visitor's feed, by the new anonymous id.
        let previous = storage.anonymousId
        client.reset()
        drain(client)
        XCTAssertNotEqual(storage.anonymousId, previous)
        XCTAssertEqual(transport.gets.last, "/feed?anonymousId=\(storage.anonymousId)")
    }

    func testPicksTheLabelsLanguage() {
        XCTAssertEqual(FeedStrings.forLanguage("ru").title, "Новости")
        XCTAssertEqual(FeedStrings.forLanguage("pt-BR").title, "Novidades")
        XCTAssertEqual(FeedStrings.forLanguage("zh-Hans-CN").pinned, "已置顶")
        XCTAssertEqual(FeedStrings.forLanguage("de_AT").dismiss, "Entfernen")
        XCTAssertEqual(FeedStrings.forLanguage("ja").title, "Updates")
        XCTAssertEqual(Set(FeedStrings.all.keys), ["en", "ru", "de", "uz", "tr", "es", "fr", "it", "pt", "zh"])
    }
}
