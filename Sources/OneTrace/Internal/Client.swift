import Foundation

/// The SDK engine. Every call goes through one serial queue in call order: events are stamped with the ids that were
/// current when they were made, disk and network never touch the main thread.
final class Client {
    static let pushToken = "cdp_token"
    static let pushURL = "cdp_url"
    private static let batchSize = 100

    let config: OneTraceConfig
    let device: DeviceContext
    let queue: DispatchQueue
    private let storage: Storage
    private let events: EventQueue
    private let transport: Transport
    private let clock: () -> Date
    private var timer: DispatchSourceTimer?

    /// Whether the user allows notifications; refreshed by the app layer before registrations.
    var notificationsEnabled: () -> Bool

    /// Shows in-app messages; set by `OneTrace.setup` (nil in tests that do not need it).
    var presenter: (([String: Any]) -> Void)?

    /// Holds in-app messages back while true.
    var inAppPaused = false

    /// In-app messages received but not shown yet (SDK queue only).
    private var inApp: [[String: Any]] = []
    private var seen: [String] = []
    /// Taps already reported: the delegate and a wrapper (firebase_messaging and the like) may both pass one on.
    private var openedTokens: [String] = []

    init(
        config: OneTraceConfig,
        storage: Storage,
        events: EventQueue,
        transport: Transport,
        device: DeviceContext,
        queue: DispatchQueue = DispatchQueue(label: "pro.onetrace.sdk"),
        clock: @escaping () -> Date = Date.init,
        notificationsEnabled: @escaping () -> Bool = { false }
    ) {
        self.config = config
        self.storage = storage
        self.events = events
        self.transport = transport
        self.device = device
        self.queue = queue
        self.clock = clock
        self.notificationsEnabled = notificationsEnabled
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + config.flushInterval, repeating: config.flushInterval)
        timer.setEventHandler { [weak self] in self?.flushNow() }
        timer.resume()
        self.timer = timer
        queue.async { self.registerNow(force: true) }
    }

    func track(_ event: String, _ properties: [String: Any?]) {
        queue.async {
            self.enqueue("track", ["event": event, "properties": Json.object(properties)])
            self.presentInApp(event)
        }
    }

    func screen(_ name: String, _ properties: [String: Any?]) {
        queue.async { self.enqueue("screen", ["name": name, "properties": Json.object(properties)]) }
    }

    func identify(_ userId: String?, _ traits: [String: Any?], _ userHash: String?) {
        queue.async {
            let changed = userId != nil && userId != self.storage.userId
            // A signature belongs to its user id: a new user drops the previous one, the same user keeps it until a new one.
            let signed = userId != nil && userHash != nil && userHash != self.storage.userHash
            if let userId = userId { self.storage.userId = userId }
            if changed || signed { self.storage.userHash = userHash }
            self.enqueue("identify", ["traits": Json.object(traits)])
            // Another user on this installation: the platform moves it to them without merging the profiles. A new
            // signature re-registers too: with a required signature an unsigned user id was not accepted.
            if changed || signed { self.registerNow(force: false) }
        }
    }

    func alias(_ userId: String, _ userHash: String?) {
        queue.async {
            let previous = self.storage.userId ?? self.storage.anonymousId
            self.storage.userId = userId
            self.storage.userHash = userHash
            self.enqueue("alias", ["previousId": previous])
            self.registerNow(force: false)
        }
    }

    func reset() {
        queue.async {
            self.flushNow()
            self.storage.userId = nil
            self.storage.userHash = nil
            self.storage.newAnonymousId()
            self.registerNow(force: false)
        }
    }

    func flush() {
        queue.async { self.flushNow() }
    }

    func setPushToken(_ token: String?, provider: String) {
        queue.async {
            self.storage.pushToken = token
            self.storage.pushProvider = token == nil ? nil : provider
            self.registerNow(force: false)
        }
    }

    func refreshRegistration() {
        queue.async { self.registerNow(force: false) }
    }

    func appLaunched() {
        queue.async {
            let version = self.device.appVersion
            let build = self.device.appBuild
            let previous = self.storage.appVersion

            if self.config.trackLifecycle {
                if previous == nil {
                    self.enqueue("track", ["event": "app_installed", "properties": ["version": version, "build": build]])
                } else if previous != version || self.storage.appBuild != build {
                    self.enqueue("track", ["event": "app_updated", "properties": [
                        "version": version, "build": build, "previous_version": previous ?? "", "previous_build": self.storage.appBuild ?? "",
                    ]])
                }
            }

            self.storage.appVersion = version
            self.storage.appBuild = build
        }
    }

    func appForeground(fromBackground: Bool) {
        queue.async {
            if self.config.trackLifecycle {
                self.enqueue("track", ["event": "app_opened", "properties": ["from_background": fromBackground, "version": self.device.appVersion]])
            }
            if fromBackground { self.registerNow(force: false) }
            self.fetchInAppNow()
            self.presentInApp(nil)
        }
    }

    func appBackground(done: (() -> Void)? = nil) {
        queue.async {
            if self.config.trackLifecycle {
                self.enqueue("track", ["event": "app_backgrounded", "properties": [String: Any]()])
            }
            self.flushNow()
            done?()
        }
    }

    /// A OneTrace notification was opened: reports the open (and the click on its link) once. Returns the link to open.
    @discardableResult
    func notificationOpened(_ userInfo: [AnyHashable: Any]) -> URL? {
        guard let token = userInfo[Self.pushToken] as? String else { return nil }
        let first: Bool = queue.sync {
            guard !openedTokens.contains(token) else { return false }
            openedTokens.append(token)
            if openedTokens.count > 50 { openedTokens.removeFirst() }
            return true
        }
        guard first else { return nil }
        let url = (userInfo[Self.pushURL] as? String).flatMap { $0.isEmpty ? nil : $0 }
        queue.async { self.pushEventNow(token, "opened", url) }
        return url.flatMap(URL.init(string:))
    }

    /// A OneTrace notification reached the app: the message becomes delivered.
    func notificationReceived(_ userInfo: [AnyHashable: Any]) {
        guard let token = userInfo[Self.pushToken] as? String else { return }
        queue.async { self.pushEventNow(token, "received", nil) }
    }

    /// Asks the platform for in-app messages now.
    func fetchInApp() {
        queue.async {
            self.fetchInAppNow()
            self.presentInApp(nil)
        }
    }

    func reportInApp(_ token: String, _ event: String, _ url: String?) {
        queue.async {
            var body: [String: Any] = ["token": token, "event": event]
            if let url = url { body["url"] = url }
            let result = self.transport.post("/in-app/events", body)
            self.log("In-app \(event) reported: HTTP \(result.status)")
        }
    }

    var anonymousId: String { queue.sync { storage.anonymousId } }

    var userId: String? { queue.sync { storage.userId } }

    var installationId: String { storage.installationId }

    private func enqueue(_ type: String, _ fields: [String: Any]) {
        var message = fields
        message["type"] = type
        message["messageId"] = UUID().uuidString.lowercased()
        message["anonymousId"] = storage.anonymousId
        message["timestamp"] = Json.iso(clock())
        message["context"] = device.build()
        if let userId = storage.userId {
            message["userId"] = userId
            if let userHash = storage.userHash { message["userHash"] = userHash }
        }
        events.add(message)
        log("Queued \(type) \(fields["event"] ?? fields["name"] ?? "")")

        if events.count >= config.flushAt { flushNow() }
    }

    private func flushNow() {
        while events.count > 0 {
            let batch = events.peek(Self.batchSize)
            let result = transport.post("/batch", ["batch": batch])

            if result.successful {
                events.remove(batch.count)
                log("Sent \(batch.count) events")
                // The events may have started a journey with an in-app message: pick it up.
                if events.count == 0 {
                    fetchInAppNow()
                    presentInApp(nil)
                }
            } else if result.status == 401 || result.status == 403 {
                // A wrong key: the events wait until a new app version fixes it.
                log("The write key was rejected (HTTP \(result.status))")
                return
            } else if result.retryable {
                log("Sending later: HTTP \(result.status) \(result.body.prefix(200))")
                return
            } else {
                // The platform would reject this batch again: drop it so the queue keeps moving.
                events.remove(batch.count)
                log("Dropped \(batch.count) events: HTTP \(result.status) \(result.body.prefix(500))")
            }
        }
    }

    private func fetchInAppNow() {
        var query = URLComponents()
        query.queryItems = [URLQueryItem(name: "anonymousId", value: storage.anonymousId), URLQueryItem(name: "appId", value: device.bundleId), URLQueryItem(name: "platform", value: "ios")]
        let result = transport.get("/in-app/messages?" + (query.percentEncodedQuery ?? ""))

        guard result.successful,
              let json = (try? JSONSerialization.jsonObject(with: Data(result.body.utf8))) as? [String: Any],
              let data = json["data"] as? [[String: Any]] else {
            log("In-app messages: HTTP \(result.status)")
            return
        }

        for message in data {
            guard let token = message["token"] as? String, !token.isEmpty, !seen.contains(token) else { continue }
            seen.append(token)
            inApp.append(message)
        }

        if seen.count > 200 { seen.removeFirst(seen.count - 200) }
    }

    /// Shows the messages for this moment: every message without a trigger after a fetch, or one triggered by `event`.
    private func presentInApp(_ event: String?) {
        guard let show = presenter, !inAppPaused else { return }

        let trigger = { (message: [String: Any]) -> String? in (message["trigger_event"] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        var matching = inApp.filter { trigger($0) == event }
        if event != nil { matching = Array(matching.prefix(1)) }

        let tokens = Set(matching.compactMap { $0["token"] as? String })
        inApp.removeAll { tokens.contains($0["token"] as? String ?? "") }
        matching.forEach(show)
    }

    private func registerNow(force: Bool) {
        let payload = registration()
        let fingerprint = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])).flatMap { String(data: $0, encoding: .utf8) }

        if !force && fingerprint != nil && fingerprint == storage.registration { return }

        let result = transport.post("/devices", payload)

        if result.successful {
            storage.registration = fingerprint
            log("Registered the installation: \(result.body)")
        } else {
            storage.registration = nil
            log("Device registration failed: HTTP \(result.status) \(result.body.prefix(300))")
        }
    }

    private func registration() -> [String: Any] {
        let push: [String: Any]
        if let token = storage.pushToken {
            push = ["provider": storage.pushProvider ?? "apns", "token": token, "enabled": notificationsEnabled()]
        } else {
            push = ["enabled": false]
        }

        var registration: [String: Any] = [
            "installationId": storage.installationId,
            "anonymousId": storage.anonymousId,
            "userId": storage.userId.map { $0 as Any } ?? NSNull(),
            "app": ["id": device.bundleId, "version": device.appVersion, "build": device.appBuild],
            "os": ["name": "ios", "version": device.osVersion],
            "device": ["manufacturer": "Apple", "model": device.model],
            "locale": device.locale,
            "timezone": device.timezone,
            "push": push,
            "sdk": ["name": device.sdk.name, "version": device.sdk.version],
        ]
        if storage.userId != nil, let userHash = storage.userHash { registration["userHash"] = userHash }

        return registration
    }

    private func pushEventNow(_ token: String, _ event: String, _ url: String?) {
        var body: [String: Any] = ["token": token, "event": event]
        if let url = url { body["url"] = url }
        let result = transport.post("/push/events", body)
        log("Push \(event) reported: HTTP \(result.status)")
    }

    private func log(_ message: @autoclosure () -> String) {
        if config.debug { print("[OneTrace] \(message())") }
    }
}
