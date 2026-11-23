import Foundation
import OneTracePush

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
    /// The message feed; its `…Now` methods run on `queue`.
    let feed: Feed
    /// Remote Config values; read from any thread.
    let remoteConfig: RemoteConfigStore
    /// Runs listener callbacks: the main thread in the app.
    private let deliver: (@escaping () -> Void) -> Void

    /// What this installation can show: `rich` and `silent` always, `live_activities` when the user allows them.
    var pushCapabilities: () -> [String] = { ["rich", "silent"] }

    /// Gets the changed Remote Config keys through `deliver`.
    var onRemoteConfigChange: ((Set<String>) -> Void)?

    /// Live Activity reports not delivered yet (no network); sent again when the app opens.
    private var pendingLiveActivities: [[String: Any]] = []

    /// Whether the user allows notifications; refreshed by the app layer before registrations.
    var notificationsEnabled: () -> Bool

    /// Shows in-app messages; set by `OneTrace.setup` (nil in tests that do not need it).
    var presenter: (([String: Any]) -> Void)?

    /// Holds in-app messages back while true.
    var inAppPaused = false

    /// In-app messages received but not shown yet (SDK queue only).
    private var inApp: [[String: Any]] = []
    private var seen: [String] = []
    /// Taps already reported, by token and button: the delegate and a wrapper (firebase_messaging and the like) may
    /// both pass one on.
    private var openedTaps: [String] = []

    init(
        config: OneTraceConfig,
        storage: Storage,
        events: EventQueue,
        transport: Transport,
        device: DeviceContext,
        queue: DispatchQueue = DispatchQueue(label: "pro.onetrace.sdk"),
        clock: @escaping () -> Date = Date.init,
        notificationsEnabled: @escaping () -> Bool = { false },
        deliver: @escaping (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) }
    ) {
        self.config = config
        self.storage = storage
        self.events = events
        self.transport = transport
        self.device = device
        self.queue = queue
        self.clock = clock
        self.notificationsEnabled = notificationsEnabled
        self.deliver = deliver
        remoteConfig = RemoteConfigStore(defaults: storage.defaults)
        let debug = config.debug
        feed = Feed(transport: transport, anonymousId: { storage.anonymousId }, log: { message in if debug { print("[OneTrace] \(message)") } }, deliver: deliver)
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + config.flushInterval, repeating: config.flushInterval)
        timer.setEventHandler { [weak self] in self?.flushNow() }
        timer.resume()
        self.timer = timer
        queue.async {
            self.registerNow(force: true)
            self.fetchRemoteConfigNow(force: false)
        }
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
            // Another profile may get other values.
            if changed { self.fetchRemoteConfigNow(force: true) }
        }
    }

    func alias(_ userId: String, _ userHash: String?) {
        queue.async {
            let previous = self.storage.userId ?? self.storage.anonymousId
            self.storage.userId = userId
            self.storage.userHash = userHash
            self.enqueue("alias", ["previousId": previous])
            self.registerNow(force: false)
            self.fetchRemoteConfigNow(force: true)
        }
    }

    func reset() {
        queue.async {
            self.flushNow()
            self.storage.userId = nil
            self.storage.userHash = nil
            self.storage.newAnonymousId()
            self.registerNow(force: false)
            self.fetchRemoteConfigNow(force: true)
            self.feed.resetNow()
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
            self.fetchRemoteConfigNow(force: false)
            self.sendLiveActivitiesNow()
            self.fetchInAppNow()
            self.presentInApp(nil)
            self.feed.refreshIfUsedNow()
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

    /// A tap on a OneTrace notification (`action` nil) or on one of its buttons (`action` — the button id, `b1`…`b3`):
    /// reports the open with the button once — the delegate and a wrapper may both pass it on; «close» reports
    /// nothing. Nil when there is nothing to do: not a OneTrace notification, an unknown button, a repeat.
    func notificationAction(_ userInfo: [AnyHashable: Any], action: String?) -> PushOpen? {
        let message = PushMessage(userInfo)
        guard let token = message.token, message.kind != .ping else { return nil }

        let action = action.flatMap { $0.isEmpty ? nil : $0 }
        var button: PushButton?
        if let action = action {
            guard let pressed = message.button(action), pressed.action != .dismiss else { return nil }
            button = pressed
        }

        let tap = token + "\u{1F}" + (action ?? "")
        let first: Bool = queue.sync {
            guard !openedTaps.contains(tap) else { return false }
            openedTaps.append(tap)
            if openedTaps.count > 50 { openedTaps.removeFirst() }
            return true
        }
        guard first else { return nil }

        let url: URL?
        switch button?.action {
        case nil: url = selectedCard(token) ?? message.url
        case .openURL?: url = button?.url
        default: url = nil
        }
        queue.async { self.pushEventNow(token, "opened", url?.absoluteString, action: action) }
        return PushOpen(url: url, button: button, message: message)
    }

    /// A tap on a OneTrace notification: reports the open (and the click on its link) once. Returns the link to open.
    @discardableResult
    func notificationOpened(_ userInfo: [AnyHashable: Any]) -> URL? {
        notificationAction(userInfo, action: nil)?.url
    }

    /// A OneTrace notification reached the app: the message becomes delivered. The local copy of «Remind me later»
    /// and the silent check do not count.
    func notificationReceived(_ userInfo: [AnyHashable: Any]) {
        let message = PushMessage(userInfo)
        guard let token = message.token, message.kind != .ping, !message.snoozed else { return }
        queue.async { self.pushEventNow(token, "received", nil) }
    }

    /// The carousel card tapped in the Notification Content Extension, through the App Group.
    private func selectedCard(_ token: String) -> URL? {
        guard let group = config.appGroup, let defaults = UserDefaults(suiteName: group) else { return nil }
        return CarouselSelection.take(token: token, from: defaults, now: clock())
    }

    /// Asks for Remote Config values unless they were asked for within the interval (or `force`).
    func fetchRemoteConfig(force: Bool, _ completion: ((Bool) -> Void)?) {
        queue.async {
            let changed = self.fetchRemoteConfigNow(force: force)
            if let completion = completion { self.deliver { completion(changed) } }
        }
    }

    /// A Live Activity event for `POST /live-activities`: `start_token`, `started`, `token`, `ended`, `dismissed`.
    func reportLiveActivity(type: String, key: String?, event: String, token: String?) {
        queue.async {
            var body: [String: Any] = ["installationId": self.storage.installationId, "type": type, "event": event]
            if let key = key { body["key"] = key }
            if let token = token { body["token"] = token }
            self.pendingLiveActivities.append(body)
            if self.pendingLiveActivities.count > 50 { self.pendingLiveActivities.removeFirst() }
            self.sendLiveActivitiesNow()
        }
    }

    /// `none`, `foreground` or `always` from `OneTraceLocation`: re-registers the installation when it changed.
    func setLocationPermission(_ permission: String) {
        queue.async {
            guard self.storage.locationPermission != permission else { return }
            self.storage.locationPermission = permission
            self.registerNow(force: false)
        }
    }

    /// `GET /geofences` of this app for `OneTraceLocation`, conditional on the version it has.
    func loadGeofences(etag: String?, _ completion: @escaping (HttpResult) -> Void) {
        queue.async {
            var query = URLComponents()
            query.queryItems = [URLQueryItem(name: "appId", value: self.device.bundleId), URLQueryItem(name: "platform", value: "ios")]
            let headers = etag.map { ["If-None-Match": $0] } ?? [:]
            let result = self.transport.get("/geofences?" + (query.percentEncodedQuery ?? ""), headers: headers)
            self.log("Geofences: HTTP \(result.status)")
            completion(result)
        }
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

    /// Loads the message feed; `completion` gets the cards through `feed.deliver` (the main thread in the app).
    func fetchFeed(_ completion: (([OneTraceFeedCard]) -> Void)?) {
        queue.async {
            let cards = self.feed.fetchNow()
            if let completion = completion { self.feed.deliver { completion(cards) } }
        }
    }

    func reportFeed(_ token: String, _ event: String, _ url: String?) {
        queue.async {
            switch event {
            case "shown": self.feed.shownNow(token)
            case "clicked": self.feed.clickedNow(token, url)
            default: self.feed.dismissedNow(token)
            }
        }
    }

    func observeFeedUnread(_ listener: @escaping (Int) -> Void) -> OneTraceObservation {
        observation { $0.observeUnread(listener) }
    }

    func observeFeed(_ listener: @escaping ([OneTraceFeedCard]) -> Void) -> OneTraceObservation {
        observation { $0.observeCards(listener) }
    }

    /// A feed listener added on the SDK queue; cancelling it there too keeps the order of the two.
    private func observation(_ add: @escaping (Feed) -> UUID) -> OneTraceObservation {
        let slot = ListenerSlot()
        let feed = self.feed
        queue.async {
            if !slot.cancelled { slot.id = add(feed) }
        }
        return OneTraceObservation { [queue] in
            queue.async {
                slot.cancelled = true
                if let id = slot.id { feed.removeListener(id) }
            }
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

    /// The Remote Config request: at start and when the app opens at most once per interval, at once after
    /// `identify` and `reset` (`force`). Offline and on errors the saved values stay. True when values changed.
    @discardableResult
    private func fetchRemoteConfigNow(force: Bool) -> Bool {
        let anonymousId = storage.anonymousId
        let now = clock()
        guard force || remoteConfig.due(now: now, minInterval: config.remoteConfigMinFetchInterval, anonymousId: anonymousId) else { return false }

        var query = URLComponents()
        query.queryItems = [
            URLQueryItem(name: "anonymousId", value: anonymousId), URLQueryItem(name: "appId", value: device.bundleId),
            URLQueryItem(name: "platform", value: "ios"), URLQueryItem(name: "appVersion", value: device.appVersion),
        ]
        let headers = remoteConfig.etag.map { ["If-None-Match": $0] } ?? [:]
        let result = transport.get("/app/config?" + (query.percentEncodedQuery ?? ""), headers: headers)

        if result.status == 304 {
            remoteConfig.touch(now: now, anonymousId: anonymousId)
            return false
        }
        // A refusal the next request would get too (402 without the plan's feature, other 4xx but 429): the saved
        // values stay and the next request waits for the interval instead of every launch.
        if (400..<500).contains(result.status), result.status != 429 {
            log("Remote Config: HTTP \(result.status), asked again after the interval")
            remoteConfig.touch(now: now, anonymousId: anonymousId)
            return false
        }
        guard result.successful, let keys = remoteConfig.apply(result.body, etag: result.headers["etag"], now: now, anonymousId: anonymousId) else {
            log("Remote Config: HTTP \(result.status) \(result.body.prefix(200))")
            return false
        }

        log("Remote Config: \(keys.count) changed")
        if !keys.isEmpty, let notify = onRemoteConfigChange { deliver { notify(keys) } }
        return !keys.isEmpty
    }

    private func sendLiveActivitiesNow() {
        while let body = pendingLiveActivities.first {
            let result = transport.post("/live-activities", body)
            if result.retryable {
                log("Live Activity \(body["event"] ?? "") later: HTTP \(result.status)")
                return
            }
            pendingLiveActivities.removeFirst()
            log("Live Activity \(body["event"] ?? "") reported: HTTP \(result.status) \(result.body.prefix(200))")
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
        var push: [String: Any]
        if let token = storage.pushToken {
            push = ["provider": storage.pushProvider ?? "apns", "token": token, "enabled": notificationsEnabled()]
        } else {
            push = ["enabled": false]
        }
        push["capabilities"] = pushCapabilities()

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
        if let permission = storage.locationPermission { registration["location"] = ["permission": permission] }

        return registration
    }

    private func pushEventNow(_ token: String, _ event: String, _ url: String?, action: String? = nil) {
        var body: [String: Any] = ["token": token, "event": event]
        if let url = url { body["url"] = url }
        if let action = action { body["action"] = action }
        let result = transport.post("/push/events", body)
        log("Push \(event) reported: HTTP \(result.status)")
    }

    private func log(_ message: @autoclosure () -> String) {
        if config.debug { print("[OneTrace] \(message())") }
    }
}

/// What a tap on a OneTrace notification or on its button did.
struct PushOpen {
    /// The link to open: the message link, the tapped carousel card or the button link; nil for «open the app» and
    /// «remind me later».
    let url: URL?
    /// The pressed button; nil for a tap on the notification.
    let button: PushButton?
    let message: PushMessage
}

/// A feed listener id, set and read on the SDK queue only.
private final class ListenerSlot {
    var id: UUID?
    var cancelled = false
}
