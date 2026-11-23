import Foundation

/// The Remote Config values of the installation from `GET /app/config`, kept between launches: until the first answer
/// and without a network the app gets the saved values, without them — its own defaults. Thread-safe: the app reads
/// values from any thread, the SDK queue writes them.
final class RemoteConfigStore {
    private let defaults: UserDefaults
    private let lock = NSLock()
    private var values: [String: Any]

    init(defaults: UserDefaults) {
        self.defaults = defaults
        values = Self.parse(defaults.string(forKey: "remote_config_values")) ?? [:]
    }

    func value(_ key: String) -> Any? {
        lock.lock()
        defer { lock.unlock() }
        return values[key]
    }

    var all: [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }

    var etag: String? { defaults.string(forKey: "remote_config_etag") }

    /// Whether a request is due: never asked, asked for another visitor, or longer ago than `minInterval`.
    func due(now: Date, minInterval: TimeInterval, anonymousId: String) -> Bool {
        guard let at = defaults.object(forKey: "remote_config_fetched_at") as? Double,
              defaults.string(forKey: "remote_config_anonymous_id") == anonymousId else { return true }
        let elapsed = now.timeIntervalSince1970 - at
        return elapsed < 0 || elapsed >= minInterval
    }

    /// A 200 answer `{"values": {…}}`: saves it and returns the keys whose values changed; nil when the body is not one.
    func apply(_ body: String, etag: String?, now: Date, anonymousId: String) -> Set<String>? {
        guard let json = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let fresh = json["values"] as? [String: Any],
              let data = try? JSONSerialization.data(withJSONObject: fresh, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return nil }

        lock.lock()
        let previous = values
        values = fresh
        lock.unlock()

        defaults.set(text, forKey: "remote_config_values")
        defaults.set(etag, forKey: "remote_config_etag")
        touch(now: now, anonymousId: anonymousId)

        let keys = Set(previous.keys).union(fresh.keys)
        return keys.filter { !Self.same(previous[$0], fresh[$0]) }
    }

    /// A 304 answer: the saved values are current.
    func touch(now: Date, anonymousId: String) {
        defaults.set(now.timeIntervalSince1970, forKey: "remote_config_fetched_at")
        defaults.set(anonymousId, forKey: "remote_config_anonymous_id")
    }

    private static func parse(_ text: String?) -> [String: Any]? {
        guard let text = text else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    }

    private static func same(_ left: Any?, _ right: Any?) -> Bool {
        switch (left, right) {
        case (nil, nil): return true
        case let (left?, right?):
            let wrap = { (value: Any) -> Data? in try? JSONSerialization.data(withJSONObject: ["v": value], options: [.sortedKeys]) }
            return wrap(left) == wrap(right)
        default: return false
        }
    }
}
