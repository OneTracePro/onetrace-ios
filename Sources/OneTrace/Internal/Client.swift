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
        queue.async { self.enqueue("track", ["event": event, "properties": Json.object(properties)]) }
    }

    func screen(_ name: String, _ properties: [String: Any?]) {
        queue.async { self.enqueue("screen", ["name": name, "properties": Json.object(properties)]) }
    }

    func identify(_ userId: String?, _ traits: [String: Any?]) {
        queue.async {
            let changed = userId != nil && userId != self.storage.userId
            if let userId = userId { self.storage.userId = userId }
            self.enqueue("identify", ["traits": Json.object(traits)])
            // Another user on this installation: the platform moves it to them without merging the profiles.
            if changed { self.registerNow(force: false) }
        }
    }

    func alias(_ userId: String) {
        queue.async {
            let previous = self.storage.userId ?? self.storage.anonymousId
            self.storage.userId = userId
            self.enqueue("alias", ["previousId": previous])
            self.registerNow(force: false)
        }
    }

    func reset() {
        queue.async {
            self.flushNow()
            self.storage.userId = nil
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

    /// A OneTrace notification was opened: reports the open (and the click on its link). Returns the link to open.
    @discardableResult
    func notificationOpened(_ userInfo: [AnyHashable: Any]) -> URL? {
        guard let token = userInfo[Self.pushToken] as? String else { return nil }
        let url = (userInfo[Self.pushURL] as? String).flatMap { $0.isEmpty ? nil : $0 }
        queue.async { self.pushEventNow(token, "opened", url) }
        return url.flatMap(URL.init(string:))
    }

    /// A OneTrace notification reached the app: the message becomes delivered.
    func notificationReceived(_ userInfo: [AnyHashable: Any]) {
        guard let token = userInfo[Self.pushToken] as? String else { return }
        queue.async { self.pushEventNow(token, "received", nil) }
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
        if let userId = storage.userId { message["userId"] = userId }
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

        return [
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
