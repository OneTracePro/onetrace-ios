import Foundation
import XCTest
@testable import OneTrace

/// Against a real project: `ONETRACE_URL=https://crm.example.com ONETRACE_KEY=cdp_wk_… swift test --filter LiveTests`.
/// Skipped without these variables.
final class LiveTests: XCTestCase {
    func testThePlatformAcceptsTheSdkRequests() throws {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["ONETRACE_URL"], let key = env["ONETRACE_KEY"], !host.isEmpty, !key.isEmpty else {
            throw XCTSkip("ONETRACE_URL and ONETRACE_KEY are not set")
        }

        let installation = "live-ios-" + UUID().uuidString.prefix(8).lowercased()
        let anonymous = "live-anon-" + UUID().uuidString.prefix(8).lowercased()
        let transport = URLSessionTransport(apiURL: OneTraceConfig(writeKey: key, host: host).apiURL, writeKey: key, userAgent: "onetrace-ios-live-test")
        let context = DeviceContext(installationId: installation).build()
        let message = { (type: String, fields: [String: Any]) -> [String: Any] in
            fields.merging(["type": type, "anonymousId": anonymous, "messageId": UUID().uuidString.lowercased(), "timestamp": Json.iso(Date()), "context": context]) { $1 }
        }

        let batch = transport.post("/batch", ["batch": [
            message("track", ["event": "app_opened", "properties": ["from_background": false]]),
            message("screen", ["name": "Catalog"]),
        ]])
        XCTAssertEqual(batch.status, 202, batch.body)

        let device = transport.post("/devices", [
            "installationId": installation, "anonymousId": anonymous,
            "app": ["id": "pro.onetrace.live.ios", "version": "1.0.0"], "os": ["name": "ios", "version": "18.1"],
            "push": ["provider": "apns", "token": "live-token-\(installation)", "enabled": true],
        ])
        XCTAssertEqual(device.status, 200, device.body)
        let answer = try JSONSerialization.jsonObject(with: Data(device.body.utf8)) as? [String: Any]
        XCTAssertEqual(answer?["push"] as? Bool, true)
    }
}
