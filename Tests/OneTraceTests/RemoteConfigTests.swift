import Foundation
import XCTest
@testable import OneTrace

final class RemoteConfigTests: XCTestCase {
    private var transport: FakeTransport!
    private var defaults: UserDefaults!
    private var now = Date(timeIntervalSince1970: 1_800_000_000)

    private static let values = #"{"values": {"banner": "winter", "new_checkout": true, "max_items": 12, "discount": 7.5, "layout": {"columns": 2}}}"#

    override func setUp() {
        transport = FakeTransport()
        defaults = UserDefaults(suiteName: "onetrace-tests-\(UUID().uuidString)")!
    }

    /// A client of the same installation: a new launch keeps what the previous one saved.
    private func client() -> Client {
        let storage = Storage(defaults: defaults)
        return Client(
            config: OneTraceConfig(writeKey: "cdp_wk_test", host: "https://crm.example.com", flushAt: 100, flushInterval: 3600, trackLifecycle: false),
            storage: storage,
            events: EventQueue(file: FileManager.default.temporaryDirectory.appendingPathComponent("onetrace-\(UUID().uuidString).jsonl"), maxSize: 50),
            transport: transport,
            device: DeviceContext(installationId: storage.installationId),
            clock: { [unowned self] in self.now },
            deliver: { $0() }
        )
    }

    private func drain(_ client: Client) {
        client.queue.sync {}
    }

    func testGivesTheValuesOfTheInstallationAndTheAppDefaultsForTheRest() {
        transport.config = (200, Self.values, "\"v1\"")
        let client = client()
        let config = OneTraceRemoteConfig { client }

        XCTAssertEqual(config.getString("banner", "summer"), "summer", "before the first answer")
        client.start()
        drain(client)

        XCTAssertEqual(config.getString("banner", "summer"), "winter")
        XCTAssertTrue(config.getBoolean("new_checkout", false))
        XCTAssertEqual(config.getLong("max_items", 5), 12)
        XCTAssertEqual(config.getDouble("discount", 0), 7.5)
        XCTAssertEqual((config.getJson("layout") as? [String: Any])?["columns"] as? Int, 2)
        XCTAssertEqual(config.getString("missing", "default"), "default")
        XCTAssertEqual(config.getLong("banner", 5), 5, "a value of another type")

        let query = transport.configGets.first ?? ""
        XCTAssertTrue(query.hasPrefix("/app/config?anonymousId=\(Storage(defaults: defaults).anonymousId)&appId="), query)
        XCTAssertTrue(query.contains("&platform=ios&appVersion="), query)
    }

    func testOfflineKeepsTheSavedValuesAndWithoutThemTheDefaults() {
        transport.config = (0, "", nil)
        let first = client()
        let config = OneTraceRemoteConfig { first }
        first.start()
        drain(first)
        XCTAssertEqual(config.getString("banner", "summer"), "summer")

        transport.config = (200, Self.values, "\"v1\"")
        now += 7200
        first.appForeground(fromBackground: true)
        drain(first)

        // The next launch, offline.
        transport.config = (0, "", nil)
        now += 7200
        let second = client()
        let next = OneTraceRemoteConfig { second }
        second.start()
        drain(second)
        XCTAssertEqual(transport.configGets.count, 3)
        XCTAssertEqual(next.getString("banner", "summer"), "winter")
        XCTAssertTrue(next.getBoolean("new_checkout", false))
    }

    func testAsksAtMostOncePerHourAndAtOnceAfterIdentifyAndReset() {
        transport.config = (200, Self.values, "\"v1\"")
        let client = client()
        client.start()
        drain(client)
        XCTAssertEqual(transport.configGets.count, 1)

        now += 1800
        client.appForeground(fromBackground: true)
        client.fetchRemoteConfig(force: false, nil)
        drain(client)
        XCTAssertEqual(transport.configGets.count, 1, "within the hour")

        client.identify("u-42", [:], nil)
        drain(client)
        XCTAssertEqual(transport.configGets.count, 2, "after identify")

        client.reset()
        drain(client)
        XCTAssertEqual(transport.configGets.count, 3, "after reset")

        now += 3600
        client.appForeground(fromBackground: true)
        drain(client)
        XCTAssertEqual(transport.configGets.count, 4, "an hour later")
    }

    func testSendsTheETagAndKeepsTheValuesOnNotModified() {
        transport.config = (200, Self.values, "\"v1\"")
        let client = client()
        let config = OneTraceRemoteConfig { client }
        client.start()
        drain(client)
        XCTAssertNil(transport.getHeaders.last?["If-None-Match"])

        transport.config = (304, "", nil)
        client.identify("u-42", [:], nil)
        drain(client)
        XCTAssertEqual(transport.getHeaders.last?["If-None-Match"], "\"v1\"")
        XCTAssertEqual(config.getString("banner", "summer"), "winter")
    }

    func testListenersGetTheChangedKeys() {
        transport.config = (200, #"{"values": {"banner": "winter", "max_items": 12}}"#, "\"v1\"")
        let client = client()
        let config = OneTraceRemoteConfig { client }
        client.onRemoteConfigChange = { config.notify($0) }
        var changes: [Set<String>] = []
        let observation = config.addListener { changes.append($0) }

        client.start()
        drain(client)
        transport.config = (200, #"{"values": {"banner": "spring", "max_items": 12}}"#, "\"v2\"")
        client.reset()
        drain(client)
        XCTAssertEqual(changes, [["banner", "max_items"], ["banner"]])

        config.removeListener(observation)
        transport.config = (200, #"{"values": {"banner": "autumn"}}"#, "\"v3\"")
        client.reset()
        drain(client)
        XCTAssertEqual(changes.count, 2)
    }
}
