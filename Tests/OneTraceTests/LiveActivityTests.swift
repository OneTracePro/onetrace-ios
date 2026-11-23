import Foundation
import XCTest
@testable import OneTrace

final class LiveActivityTests: XCTestCase {
    private var transport: FakeTransport!
    private var storage: Storage!
    private var client: Client!

    override func setUp() {
        transport = FakeTransport()
        storage = Storage(defaults: UserDefaults(suiteName: "onetrace-tests-\(UUID().uuidString)")!)
        client = Client(
            config: OneTraceConfig(writeKey: "cdp_wk_test", host: "https://crm.example.com", flushAt: 100, flushInterval: 3600, trackLifecycle: false),
            storage: storage,
            events: EventQueue(file: FileManager.default.temporaryDirectory.appendingPathComponent("onetrace-\(UUID().uuidString).jsonl"), maxSize: 50),
            transport: transport,
            device: DeviceContext(installationId: storage.installationId),
            deliver: { $0() }
        )
    }

    private func drain() {
        client.queue.sync {}
    }

    /// `content-state` of the contract: `{title, status?, step?, steps?, progress?, endsAt (UNIX seconds)?, data}`.
    func testTheContentStateIsTheContractFieldForField() throws {
        let state = OneTraceActivityAttributes.ContentState(
            title: "Order 1001", status: "On the way", step: 2, steps: ["Accepted", "Packed", "On the way", "Delivered"],
            progress: 0.5, endsAt: Date(timeIntervalSince1970: 1_800_000_000), data: ["courier": "Anna"]
        )
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as! [String: Any]

        XCTAssertEqual(Set(json.keys), ["title", "status", "step", "steps", "progress", "endsAt", "data"])
        XCTAssertEqual(json["title"] as? String, "Order 1001")
        XCTAssertEqual(json["status"] as? String, "On the way")
        XCTAssertEqual(json["step"] as? Int, 2)
        XCTAssertEqual(json["steps"] as? [String], ["Accepted", "Packed", "On the way", "Delivered"])
        XCTAssertEqual(json["progress"] as? Double, 0.5)
        XCTAssertEqual(json["endsAt"] as? Double, 1_800_000_000)
        XCTAssertEqual(json["data"] as? [String: String], ["courier": "Anna"])

        // Only the title is required: the platform leaves the rest out.
        let minimal = try JSONSerialization.jsonObject(with: JSONEncoder().encode(OneTraceActivityAttributes.ContentState(title: "Sale"))) as! [String: Any]
        XCTAssertEqual(Set(minimal.keys), ["title", "data"])

        let attributes = try JSONSerialization.jsonObject(with: JSONEncoder().encode(OneTraceActivityAttributes(type: "order", key: "1001"))) as! [String: Any]
        XCTAssertEqual(attributes as? [String: String], ["type": "order", "key": "1001"])
    }

    /// What APNs brings: `endsAt` in UNIX seconds whatever date strategy ActivityKit decodes with.
    func testDecodesTheStateThePlatformSends() throws {
        let body = #"{"title":"Заказ 1001","status":"В пути","step":2,"steps":["Принят","Собран","В пути"],"progress":0.66,"endsAt":1800000000,"data":{"order":"1001"}}"#
        let state = try JSONDecoder().decode(OneTraceActivityAttributes.ContentState.self, from: Data(body.utf8))

        XCTAssertEqual(state, OneTraceActivityAttributes.ContentState(
            title: "Заказ 1001", status: "В пути", step: 2, steps: ["Принят", "Собран", "В пути"],
            progress: 0.66, endsAt: Date(timeIntervalSince1970: 1_800_000_000), data: ["order": "1001"]
        ))

        let bare = try JSONDecoder().decode(OneTraceActivityAttributes.ContentState.self, from: Data(#"{"title":"Sale"}"#.utf8))
        XCTAssertEqual(bare, OneTraceActivityAttributes.ContentState(title: "Sale"))
    }

    func testReportsTheTokensAndTheEndOfAnActivity() {
        let activities = OneTraceLiveActivities { [unowned self] in self.client }

        activities.tokenChanged(id: "A", type: "order", key: "1001", token: "aa01")
        activities.tokenChanged(id: "A", type: "order", key: "1001", token: "aa01")
        activities.tokenChanged(id: "A", type: "order", key: "1001", token: "bb02")
        activities.finished(id: "A", type: "order", key: "1001", event: "ended")
        activities.finished(id: "A", type: "order", key: "1001", event: "ended")
        activities.tokenChanged(id: "B", type: "delivery", key: "77", token: "cc03")
        activities.finished(id: "B", type: "delivery", key: "77", event: "dismissed")
        drain()

        let reports = transport.liveActivities
        XCTAssertEqual(reports.map { $0["event"] as? String }, ["started", "token", "ended", "started", "dismissed"])
        XCTAssertEqual(reports.map { $0["token"] as? String }, ["aa01", "bb02", nil, "cc03", nil])
        XCTAssertEqual(reports.map { $0["type"] as? String }, ["order", "order", "order", "delivery", "delivery"])
        XCTAssertEqual(reports.map { $0["key"] as? String }, ["1001", "1001", "1001", "77", "77"])
        XCTAssertTrue(reports.allSatisfy { $0["installationId"] as? String == storage.installationId })
    }

    func testRegistersThePushToStartTokenOfEveryTypeWithoutAKey() {
        let activities = OneTraceLiveActivities { [unowned self] in self.client }

        activities.startTokenChanged(types: ["order", "delivery"], token: "ff10")
        activities.startTokenChanged(types: ["order", "delivery"], token: "ff10")
        drain()

        let reports = transport.liveActivities
        XCTAssertEqual(reports.map { $0["event"] as? String }, ["start_token", "start_token"])
        XCTAssertEqual(reports.map { $0["type"] as? String }, ["order", "delivery"])
        XCTAssertEqual(reports.map { $0["token"] as? String }, ["ff10", "ff10"])
        XCTAssertTrue(reports.allSatisfy { $0["key"] == nil })
        XCTAssertEqual(OneTraceLiveActivities.hex(Data([0x0a, 0xff, 0x01])), "0aff01")
    }

    func testKeepsReportsWhileOfflineAndSendsThemWhenTheAppOpens() {
        let activities = OneTraceLiveActivities { [unowned self] in self.client }
        transport.liveActivityStatus = 0
        activities.tokenChanged(id: "A", type: "order", key: "1001", token: "aa01")
        drain()
        XCTAssertEqual(transport.liveActivities.count, 1)

        transport.liveActivityStatus = 200
        client.appForeground(fromBackground: true)
        drain()
        XCTAssertEqual(transport.liveActivities.map { $0["event"] as? String }, ["started", "started"])

        client.appForeground(fromBackground: true)
        drain()
        XCTAssertEqual(transport.liveActivities.count, 2)
    }
}
