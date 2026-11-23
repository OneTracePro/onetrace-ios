import Foundation
#if canImport(ActivityKit) && os(iOS)
import ActivityKit
#endif

/// Live Activities of `OneTraceActivityAttributes` handed to OneTrace: their push tokens, token changes and ends go to
/// `POST /live-activities`, and the platform updates them through APNs. `OneTrace.liveActivities`.
public final class OneTraceLiveActivities {
    private let client: () -> Client?
    private let lock = NSLock()
    /// The last token sent per activity id; an activity tracked twice is observed once.
    private var tokens: [String: String] = [:]
    private var tracked: Set<String> = []
    private var ended: Set<String> = []
    private var startTokens: [String: String] = [:]
    private var pushToStartEnabled = false

    init(client: @escaping () -> Client?) {
        self.client = client
    }

    /// The first token of an activity is `started`, a new one — `token`, the same one again — nothing.
    func tokenChanged(id: String, type: String, key: String, token: String) {
        lock.lock()
        let previous = tokens[id]
        if previous != token { tokens[id] = token }
        lock.unlock()
        guard previous != token else { return }
        client()?.reportLiveActivity(type: type, key: key, event: previous == nil ? "started" : "token", token: token)
    }

    /// `ended` or `dismissed`, once per activity.
    func finished(id: String, type: String, key: String, event: String) {
        lock.lock()
        let first = ended.insert(id).inserted
        lock.unlock()
        guard first else { return }
        client()?.reportLiveActivity(type: type, key: key, event: event, token: nil)
    }

    /// The push-to-start token of the activity type, for every `type` the platform may start.
    func startTokenChanged(types: [String], token: String) {
        for type in types {
            lock.lock()
            let changed = startTokens[type] != token
            startTokens[type] = token
            lock.unlock()
            if changed { client()?.reportLiveActivity(type: type, key: nil, event: "start_token", token: token) }
        }
    }

    /// Marks the activity as observed; false when it already is.
    func begin(_ id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return tracked.insert(id).inserted
    }

    func beginPushToStart() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !pushToStartEnabled else { return false }
        pushToStartEnabled = true
        return true
    }

    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}

#if canImport(ActivityKit) && os(iOS)
extension OneTraceLiveActivities {
    /// Hands an activity to OneTrace: call it right after `Activity.request(…, pushType: .token)`, and for
    /// `Activity<OneTraceActivityAttributes>.activities` when the app starts — tokens change.
    @available(iOS 16.1, *)
    public func track(_ activity: Activity<OneTraceActivityAttributes>) {
        let id = activity.id
        let type = activity.attributes.type
        let key = activity.attributes.key
        guard begin(id) else { return }

        if let token = activity.pushToken {
            tokenChanged(id: id, type: type, key: key, token: Self.hex(token))
        }
        Task {
            for await token in activity.pushTokenUpdates {
                self.tokenChanged(id: id, type: type, key: key, token: Self.hex(token))
            }
        }
        Task {
            for await state in activity.activityStateUpdates {
                switch state {
                case .ended: self.finished(id: id, type: type, key: key, event: "ended")
                case .dismissed: self.finished(id: id, type: type, key: key, event: "dismissed")
                default: break
                }
            }
        }
    }

    /// Tracks the running activities of `OneTraceActivityAttributes` and those started later, by the app or by push.
    @available(iOS 16.1, *)
    public func trackAll() {
        Activity<OneTraceActivityAttributes>.activities.forEach { track($0) }
        guard beginActivityUpdates() else { return }
        Task {
            for await activity in Activity<OneTraceActivityAttributes>.activityUpdates {
                self.track(activity)
            }
        }
    }

    /// Lets the platform start activities itself (push-to-start, iOS 17.2+): registers the start token of
    /// `OneTraceActivityAttributes` for the activity `types` of your templates, and tracks the activities it starts.
    @available(iOS 17.2, *)
    public func enablePushToStart(types: [String] = ["default"]) {
        trackAll()
        guard beginPushToStart() else { return }
        if let token = Activity<OneTraceActivityAttributes>.pushToStartToken {
            startTokenChanged(types: types, token: Self.hex(token))
        }
        Task {
            for await token in Activity<OneTraceActivityAttributes>.pushToStartTokenUpdates {
                self.startTokenChanged(types: types, token: Self.hex(token))
            }
        }
    }

    /// Whether the user allows Live Activities of this app (and Info.plist has `NSSupportsLiveActivities`).
    static var available: Bool {
        if #available(iOS 16.1, *) { return ActivityAuthorizationInfo().areActivitiesEnabled }
        return false
    }

    private func beginActivityUpdates() -> Bool {
        begin("\u{0}activity-updates")
    }
}
#else
extension OneTraceLiveActivities {
    static var available: Bool { false }
}
#endif
