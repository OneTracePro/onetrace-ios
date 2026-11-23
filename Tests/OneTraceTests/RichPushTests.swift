import Foundation
import XCTest
@testable import OneTrace
import OneTracePush

final class RichPushTests: XCTestCase {
    private var transport: FakeTransport!
    private var storage: Storage!

    override func setUp() {
        transport = FakeTransport()
        storage = Storage(defaults: UserDefaults(suiteName: "onetrace-tests-\(UUID().uuidString)")!)
    }

    private func client(appGroup: String? = nil) -> Client {
        Client(
            config: OneTraceConfig(writeKey: "cdp_wk_test", host: "https://crm.example.com", flushAt: 100, flushInterval: 3600, trackLifecycle: false, appGroup: appGroup),
            storage: storage,
            events: EventQueue(file: FileManager.default.temporaryDirectory.appendingPathComponent("onetrace-\(UUID().uuidString).jsonl"), maxSize: 50),
            transport: transport,
            device: DeviceContext(installationId: storage.installationId),
            clock: { Date(timeIntervalSince1970: 1_800_000_000) },
            deliver: { $0() }
        )
    }

    private func drain(_ client: Client) {
        client.queue.sync {}
    }

    /// An APNs notification of the platform with three buttons, the lists on the top level.
    private let withButtons: [AnyHashable: Any] = [
        "aps": ["alert": ["title": "Sale", "body": "Everything −30 %"], "mutable-content": 1] as [String: Any],
        "cdp_token": "msg.abc",
        "cdp_url": "shopapp://sale",
        "cdp_buttons": [
            ["id": "b1", "title": "Buy", "action": "open_url", "url": "https://shop.example.com/cart"] as [String: Any],
            ["id": "b2", "title": "Later", "action": "snooze", "snooze_minutes": "180"] as [String: Any],
            ["id": "b3", "title": "Close", "action": "dismiss"] as [String: Any],
        ] as [[String: Any]],
    ]

    func testButtonsOfTheMessageMakeTheirOwnCategory() {
        let message = PushMessage(withButtons)

        XCTAssertEqual(message.buttons.map(\.id), ["b1", "b2", "b3"])
        XCTAssertEqual(message.buttons.map(\.title), ["Buy", "Later", "Close"])
        XCTAssertEqual(message.buttons.map(\.action), [.openURL, .snooze, .dismiss])
        XCTAssertEqual(message.buttons[0].url?.absoluteString, "https://shop.example.com/cart")
        XCTAssertEqual(message.buttons[1].snooze, .minutes(180))

        let category = message.categoryIdentifier ?? ""
        XCTAssertTrue(category.hasPrefix("cdp_buttons_"), category)
        let hash = category.dropFirst("cdp_buttons_".count)
        XCTAssertEqual(hash.count, 8)
        XCTAssertTrue(hash.allSatisfy { "0123456789abcdef".contains($0) }, String(hash))

        // Firebase data: every value is a string, the buttons a JSON string — the same buttons, the same category.
        let fcm = PushMessage([
            "cdp_token": "msg.abc",
            "cdp_buttons": #"[{"id":"b1","title":"Buy","action":"open_url","url":"https://shop.example.com/cart"},{"id":"b2","title":"Later","action":"snooze","snooze_minutes":"180"},{"id":"b3","title":"Close","action":"dismiss"}]"#,
        ])
        XCTAssertEqual(fcm.buttons, message.buttons)
        XCTAssertEqual(fcm.categoryIdentifier, category)

        let other = PushMessage(["cdp_token": "msg.def", "cdp_buttons": [["id": "b1", "title": "Open", "action": "open_app"]]])
        XCTAssertNotEqual(other.categoryIdentifier, category)
        XCTAssertTrue(other.categoryIdentifier?.hasPrefix("cdp_buttons_") ?? false)
    }

    func testCarouselAndTimerHaveFixedCategoriesWithTheButtonsUnderThem() {
        let carousel = PushMessage([
            "cdp_token": "msg.1",
            "cdp_carousel": [
                ["image": "https://cdn.example.com/1.jpg", "title": "Sneakers", "body": "4 990 ₽", "url": "shopapp://p/1"],
                ["image": "https://cdn.example.com/2.jpg", "title": "Boots", "url": "shopapp://p/2"],
            ],
            "cdp_buttons": [["id": "b1", "title": "Catalog", "action": "open_app"]],
        ])
        XCTAssertEqual(carousel.categoryIdentifier, "cdp_carousel")
        XCTAssertEqual(carousel.carousel.map(\.title), ["Sneakers", "Boots"])
        XCTAssertEqual(carousel.carousel[1].url?.absoluteString, "shopapp://p/2")
        XCTAssertEqual(carousel.buttons.map(\.id), ["b1"])

        let timer = PushMessage(["cdp_token": "msg.2", "cdp_timer_end": "2027-01-15T15:00:00Z", "cdp_buttons": [["id": "b1", "title": "Go", "action": "open_app"]]])
        XCTAssertEqual(timer.categoryIdentifier, "cdp_timer")
        XCTAssertEqual(timer.timerEnd, Date(timeIntervalSince1970: 1_800_025_200))

        // The category the platform set wins; one card is not a carousel.
        XCTAssertEqual(PushMessage(["cdp_token": "t", "aps": ["category": "cdp_buttons_0a1b2c3d"]]).categoryIdentifier, "cdp_buttons_0a1b2c3d")
        XCTAssertNil(PushMessage(["cdp_token": "t", "cdp_carousel": [["image": "https://cdn.example.com/1.jpg"]]]).categoryIdentifier)
    }

    func testTheTimerEndIsAddedToTheTextByTheDeviceClockAndLanguage() {
        let moscow = TimeZone(identifier: "Europe/Moscow")!
        let now = Date(timeIntervalSince1970: 1_800_000_000)          // 2027-01-15 11:00 in Moscow
        let end = Date(timeIntervalSince1970: 1_800_025_200)          // 2027-01-15 18:00 in Moscow

        XCTAssertEqual(
            TimerText.appending(to: "Всё со скидкой 30 %", end: end, now: now, locale: Locale(identifier: "ru_RU"), timeZone: moscow, language: "ru"),
            "Всё со скидкой 30 % · до 18:00"
        )
        XCTAssertEqual(TimerText.until(end, now: now, locale: Locale(identifier: "de_DE"), timeZone: moscow, language: "de"), "bis 18:00")

        // Another day: with the date; an ended timer leaves the text as it is.
        let tomorrow = TimerText.until(end.addingTimeInterval(86_400), now: now, locale: Locale(identifier: "ru_RU"), timeZone: moscow, language: "ru")
        XCTAssertTrue(tomorrow.hasPrefix("до 16"), tomorrow)
        XCTAssertTrue(tomorrow.hasSuffix("18:00"), tomorrow)
        XCTAssertEqual(TimerText.appending(to: "Sale", end: now.addingTimeInterval(-1), now: now), "Sale")

        XCTAssertEqual(TimerText.countdown(65), "1:05")
        XCTAssertEqual(TimerText.countdown(3 * 3600 + 7), "3:00:07")
        XCTAssertNil(TimerText.countdown(0))
        XCTAssertEqual(Set(PushStrings.all.keys), ["en", "ru", "de", "uz", "tr", "es", "fr", "it", "pt", "zh"])
    }

    func testRemindMeLaterSchedulesByIntervalOrTomorrowAtNineOnThePhoneClock() {
        XCTAssertEqual(SnoozeDelay(60)?.trigger(), .interval(3600))
        XCTAssertEqual(SnoozeDelay("180")?.trigger(), .interval(10_800))

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tashkent")!   // UTC+5
        // 2026-11-23 20:30 UTC is already 01:30 on the 24th in Tashkent: «tomorrow» is the 25th.
        let lateEvening = Date(timeIntervalSince1970: 1_795_465_800)
        XCTAssertEqual(SnoozeDelay("tomorrow")?.trigger(now: lateEvening, calendar: calendar), .calendar(DateComponents(year: 2026, month: 11, day: 25, hour: 9, minute: 0)))

        calendar.timeZone = TimeZone(identifier: "America/New_York")!   // UTC−5: still the 23rd there
        XCTAssertEqual(SnoozeDelay("tomorrow_9")?.trigger(now: lateEvening, calendar: calendar), .calendar(DateComponents(year: 2026, month: 11, day: 24, hour: 9, minute: 0)))

        XCTAssertEqual(PushMessage(["cdp_token": "t", "cdp_buttons": [["id": "b1", "title": "Tomorrow", "action": "snooze", "snooze_minutes": "tomorrow_9"]]]).buttons.first?.snooze, .tomorrowMorning)
        XCTAssertNil(SnoozeDelay("soon"))
        XCTAssertNil(SnoozeDelay(0))
        // A snooze button without a delay waits an hour.
        XCTAssertEqual(PushMessage(["cdp_token": "t", "cdp_buttons": [["id": "b1", "title": "Later", "action": "snooze"]]]).buttons.first?.snooze, .minutes(60))
    }

    func testAButtonReportsTheOpenWithItsIdOnceAndCloseReportsNothing() {
        let client = client()

        let buy = client.notificationAction(withButtons, action: "b1")
        XCTAssertEqual(buy?.url?.absoluteString, "https://shop.example.com/cart")
        XCTAssertEqual(buy?.button?.action, .openURL)
        XCTAssertNil(client.notificationAction(withButtons, action: "b1"), "the delegate and a wrapper pass the same press on")
        XCTAssertNil(client.notificationAction(withButtons, action: "b3"), "close")
        XCTAssertNil(client.notificationAction(withButtons, action: "b9"), "not a button of this message")

        let later = client.notificationAction(withButtons, action: "b2")
        XCTAssertNil(later?.url)
        XCTAssertEqual(later?.button?.snooze, .minutes(180))

        // A tap on the notification itself is another tap: it opens the message link.
        XCTAssertEqual(client.notificationOpened(withButtons)?.absoluteString, "shopapp://sale")
        drain(client)

        let events = transport.pushEvents
        XCTAssertEqual(events.map { $0["event"] as? String }, ["opened", "opened", "opened"])
        XCTAssertEqual(events.map { $0["action"] as? String }, ["b1", "b2", nil])
        XCTAssertEqual(events.map { $0["url"] as? String }, ["https://shop.example.com/cart", nil, "shopapp://sale"])
        XCTAssertEqual(events.map { $0["token"] as? String }, ["msg.abc", "msg.abc", "msg.abc"])
    }

    func testTheSilentCheckAndTheSnoozedCopyAreNotReported() {
        let client = client()
        // The platform puts `cdp_kind` next to `aps` in the APNs payload.
        let ping: [AnyHashable: Any] = ["aps": ["content-available": 1], "cdp_kind": "ping"]
        XCTAssertEqual(PushMessage(ping).kind, .ping)
        XCTAssertEqual(PushMessage(["cdp_kind": "ping"]).kind, .ping)
        XCTAssertTrue(OneTrace.isSilentCheck(ping))
        // A background push of the app itself (or of another service) is not the check: the app handles it.
        let foreign: [AnyHashable: Any] = ["aps": ["content-available": 1], "sync": "orders"]
        XCTAssertEqual(PushMessage(foreign).kind, .notification)
        XCTAssertFalse(OneTrace.isSilentCheck(foreign))
        XCTAssertFalse(OneTrace.isOneTraceNotification(foreign))
        XCTAssertNil(client.notificationOpened(ping))
        client.notificationReceived(ping)

        var copy = withButtons
        copy["cdp_snoozed"] = "1"
        client.notificationReceived(copy)
        drain(client)
        XCTAssertTrue(transport.pushEvents.isEmpty)

        // Opening the copy counts for the same message.
        XCTAssertEqual(client.notificationOpened(copy)?.absoluteString, "shopapp://sale")
        drain(client)
        XCTAssertEqual(transport.pushEvents.map { $0["token"] as? String }, ["msg.abc"])
    }

    func testATappedCarouselCardOpensItsLinkThroughTheAppGroup() {
        let group = "group.onetrace.tests.\(UUID().uuidString)"
        let shared = UserDefaults(suiteName: group)!
        let client = client(appGroup: group)
        let message: [AnyHashable: Any] = ["cdp_token": "msg.c", "cdp_url": "shopapp://sale"]

        CarouselSelection.save(token: "msg.c", url: URL(string: "shopapp://p/2")!, in: shared, now: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(client.notificationOpened(message)?.absoluteString, "shopapp://p/2")
        drain(client)
        XCTAssertEqual(transport.pushEvents.last?["url"] as? String, "shopapp://p/2")
        XCTAssertNil(shared.dictionary(forKey: "pro.onetrace.carousel.selection"))
    }

    func testTheInstallationReportsWhatItCanShowAndTheLocationPermission() {
        let client = client()
        client.pushCapabilities = { ["rich", "live_activities", "silent"] }
        client.start()
        drain(client)
        let push = transport.registrations.last?["push"] as? [String: Any]
        XCTAssertEqual(push?["capabilities"] as? [String], ["rich", "live_activities", "silent"])
        XCTAssertNil(transport.registrations.last?["location"])

        client.setLocationPermission("always")
        client.setLocationPermission("always")
        drain(client)
        XCTAssertEqual(transport.registrations.count, 2)
        XCTAssertEqual((transport.registrations.last?["location"] as? [String: Any])?["permission"] as? String, "always")
    }
}
