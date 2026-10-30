import Foundation
import XCTest
@testable import OneTrace

final class FakeTransport: Transport {
    struct Request {
        let path: String
        let body: [String: Any]
    }

    private let lock = NSLock()
    private(set) var requests: [Request] = []
    private(set) var gets: [String] = []
    var batchStatus = 202
    var inApp = "{\"data\": []}"

    func get(_ path: String) -> HttpResult {
        lock.lock()
        defer { lock.unlock() }
        gets.append(path)
        return HttpResult(status: 200, body: inApp)
    }

    func post(_ path: String, _ body: [String: Any]) -> HttpResult {
        lock.lock()
        defer { lock.unlock() }
        // Round-trip through JSON: what the platform would receive.
        let data = try! JSONSerialization.data(withJSONObject: body)
        requests.append(Request(path: path, body: try! JSONSerialization.jsonObject(with: data) as! [String: Any]))
        return HttpResult(status: path == "/batch" ? batchStatus : 200, body: "{}")
    }

    var events: [[String: Any]] { requests.filter { $0.path == "/batch" }.flatMap { $0.body["batch"] as! [[String: Any]] } }

    var registrations: [[String: Any]] { requests.filter { $0.path == "/devices" }.map(\.body) }
}

final class ClientTests: XCTestCase {
    private var transport: FakeTransport!
    private var storage: Storage!
    private var queueFile: URL!
    private var notifications = true

    override func setUp() {
        transport = FakeTransport()
        let suite = "onetrace-tests-\(UUID().uuidString)"
        storage = Storage(defaults: UserDefaults(suiteName: suite)!)
        queueFile = FileManager.default.temporaryDirectory.appendingPathComponent("onetrace-\(UUID().uuidString).jsonl")
    }

    private func client(flushAt: Int = 3, trackLifecycle: Bool = false) -> Client {
        Client(
            config: OneTraceConfig(writeKey: "cdp_wk_test", host: "https://crm.example.com/", flushAt: flushAt, flushInterval: 3600, trackLifecycle: trackLifecycle),
            storage: storage,
            events: EventQueue(file: queueFile, maxSize: 50),
            transport: transport,
            device: DeviceContext(installationId: storage.installationId),
            clock: { Date(timeIntervalSince1970: 1_800_000_000) },
            notificationsEnabled: { [unowned self] in self.notifications }
        )
    }

    /// Waits until the SDK queue has processed everything submitted so far.
    private func drain(_ client: Client) {
        client.queue.sync {}
    }

    func testApiUrlFromTheHost() {
        XCTAssertEqual(OneTraceConfig(writeKey: "k", host: "https://crm.example.com/").apiURL, "https://crm.example.com/api/v1")
        XCTAssertEqual(OneTraceConfig(writeKey: "k", host: " https://crm.example.com/api/v1 ").apiURL, "https://crm.example.com/api/v1")
    }

    func testSendsEventsInBatchesWithTheAppContext() {
        let client = client()
        client.track("order_completed", ["amount": 1250.5, "items": ["SKU-1"], "paid_at": Date(timeIntervalSince1970: 0)])
        client.screen("Cart", [:])
        drain(client)
        XCTAssertTrue(transport.events.isEmpty)

        client.track("checkout_started", [:])
        drain(client)

        let events = transport.events
        XCTAssertEqual(events.map { $0["type"] as? String }, ["track", "screen", "track"])
        let properties = events[0]["properties"] as! [String: Any]
        XCTAssertEqual(properties["amount"] as? Double, 1250.5)
        XCTAssertEqual(properties["paid_at"] as? String, "1970-01-01T00:00:00.000Z")
        XCTAssertEqual(events[1]["name"] as? String, "Cart")
        XCTAssertEqual(events[0]["timestamp"] as? String, "2027-01-15T08:00:00.000Z")
        XCTAssertEqual(events[0]["anonymousId"] as? String, storage.anonymousId)

        let context = events[0]["context"] as! [String: Any]
        XCTAssertEqual((context["device"] as! [String: Any])["id"] as? String, storage.installationId)
        XCTAssertEqual((context["os"] as! [String: Any])["name"] as? String, "ios")
        XCTAssertEqual((context["library"] as! [String: Any])["name"] as? String, "onetrace-ios")
        XCTAssertEqual(EventQueue(file: queueFile, maxSize: 50).count, 0)
    }

    func testKeepsEventsOnDiskWhileTheNetworkFailsAndDropsBatchesThePlatformRejects() {
        transport.batchStatus = 0
        let client = client(flushAt: 1)
        client.track("viewed", [:])
        drain(client)
        XCTAssertEqual(EventQueue(file: queueFile, maxSize: 50).count, 1)

        transport.batchStatus = 422
        client.flush()
        drain(client)
        XCTAssertEqual(EventQueue(file: queueFile, maxSize: 50).count, 0)
    }

    func testRegistersTheInstallationWithThePushTokenOnlyWhenSomethingChanged() {
        let client = client()
        client.start()
        client.setPushToken("apns-token", provider: "apns")
        client.setPushToken("apns-token", provider: "apns")
        drain(client)

        let registrations = transport.registrations
        XCTAssertEqual(registrations.count, 2)
        XCTAssertEqual((registrations[0]["push"] as! [String: Any])["enabled"] as? Bool, false)

        let push = registrations[1]["push"] as! [String: Any]
        XCTAssertEqual(push["provider"] as? String, "apns")
        XCTAssertEqual(push["token"] as? String, "apns-token")
        XCTAssertEqual(push["enabled"] as? Bool, true)
        XCTAssertEqual(registrations[1]["installationId"] as? String, storage.installationId)
        XCTAssertEqual((registrations[1]["os"] as! [String: Any])["name"] as? String, "ios")
        XCTAssertEqual((registrations[1]["sdk"] as! [String: Any])["name"] as? String, "ios")

        notifications = false
        client.refreshRegistration()
        drain(client)
        XCTAssertEqual((transport.registrations.last!["push"] as! [String: Any])["enabled"] as? Bool, false)
    }

    func testMovesTheInstallationToTheNextUserOnIdentifyAndReset() {
        let client = client(flushAt: 1)
        let anonymous = storage.anonymousId
        client.identify("u-42", ["email": "anna@example.com"])
        drain(client)

        let identify = transport.events.last!
        XCTAssertEqual(identify["userId"] as? String, "u-42")
        XCTAssertEqual((identify["traits"] as! [String: Any])["email"] as? String, "anna@example.com")
        XCTAssertEqual(transport.registrations.last!["userId"] as? String, "u-42")

        client.reset()
        client.track("viewed", [:])
        drain(client)

        XCTAssertNil(storage.userId)
        XCTAssertNotEqual(storage.anonymousId, anonymous)
        XCTAssertTrue(transport.registrations.last!["userId"] is NSNull)
        XCTAssertEqual(transport.registrations.last!["anonymousId"] as? String, storage.anonymousId)
        XCTAssertNil(transport.events.last!["userId"])
    }

    func testTracksInstallsAndUpdates() {
        storage.appVersion = nil
        let first = client(flushAt: 1, trackLifecycle: true)
        first.appLaunched()
        drain(first)
        storage.appVersion = "0.9"
        let second = client(flushAt: 1, trackLifecycle: true)
        second.appLaunched()
        drain(second)

        XCTAssertEqual(transport.events.map { $0["event"] as? String }, ["app_installed", "app_updated"])
        XCTAssertEqual((transport.events[1]["properties"] as! [String: Any])["previous_version"] as? String, "0.9")
    }

    func testReportsOpenedAndReceivedNotifications() {
        let client = client()
        let url = client.notificationOpened(["cdp_token": "abc.def", "cdp_url": "shopapp://sale", "aps": ["alert": "Sale"]])
        client.notificationReceived(["cdp_token": "abc.def"])
        drain(client)

        XCTAssertEqual(url?.absoluteString, "shopapp://sale")
        let events = transport.requests.filter { $0.path == "/push/events" }.map(\.body)
        XCTAssertEqual(events.map { $0["event"] as? String }, ["opened", "received"])
        XCTAssertEqual(events[0]["url"] as? String, "shopapp://sale")
        XCTAssertNil(client.notificationOpened(["aps": ["alert": "Not ours"]]))
    }

    func testReportsATapOnceWhenTheDelegateAndTheWrapperBothPassItOn() {
        let client = client()
        XCTAssertNotNil(client.notificationOpened(["cdp_token": "abc.def", "cdp_url": "shopapp://sale"]))
        XCTAssertNil(client.notificationOpened(["cdp_token": "abc.def", "cdp_url": "shopapp://sale"]))
        drain(client)

        XCTAssertEqual(transport.requests.filter { $0.path == "/push/events" }.count, 1)
    }

    func testKeepsTheNewestEventsWhenTheQueueIsFull() {
        let queue = EventQueue(file: queueFile, maxSize: 3)
        (1...5).forEach { queue.add(["n": $0]) }

        XCTAssertEqual(EventQueue(file: queueFile, maxSize: 3).peek(10).map { $0["n"] as? Int }, [3, 4, 5])
    }

    func testShowsInAppMessagesAfterAFetchOrAfterTheirTriggerEvent() {
        var shown: [String] = []
        let client = client(flushAt: 100)
        client.presenter = { shown.append($0["title"] as? String ?? "") }
        transport.inApp = #"{"data": [{"token": "t1", "title": "Welcome", "trigger_event": null}, {"token": "t2", "title": "Cart reminder", "trigger_event": "add_to_cart"}]}"#

        client.fetchInApp()
        client.fetchInApp()
        drain(client)
        XCTAssertEqual(shown, ["Welcome"])
        XCTAssertTrue(transport.gets[0].hasPrefix("/in-app/messages?anonymousId=\(storage.anonymousId)&appId="))
        XCTAssertTrue(transport.gets[0].hasSuffix("&platform=ios"))

        client.track("product_viewed", [:])
        client.track("add_to_cart", [:])
        client.track("add_to_cart", [:])
        drain(client)
        XCTAssertEqual(shown, ["Welcome", "Cart reminder"])

        client.reportInApp("t2", "clicked", "shopapp://cart")
        drain(client)
        let event = transport.requests.first { $0.path == "/in-app/events" }!.body
        XCTAssertEqual(event["event"] as? String, "clicked")
        XCTAssertEqual(event["url"] as? String, "shopapp://cart")
    }
}
