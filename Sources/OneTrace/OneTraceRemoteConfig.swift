import Foundation

/// Remote Config: app parameters set in OneTrace (Apps → App settings) with values by segment, without a new app
/// version. `OneTrace.remoteConfig.getBoolean("new_checkout", false)`.
///
/// The SDK asks for the values when the app starts and opens again, at most once per
/// `OneTraceConfig.remoteConfigMinFetchInterval` (an hour by default), and at once after `identify` and `reset`.
/// Until the first answer and offline the getters return the saved values; without them — the default you pass.
public final class OneTraceRemoteConfig {
    private let client: () -> Client?
    private let lock = NSLock()
    private var listeners: [UUID: (Set<String>) -> Void] = [:]

    init(client: @escaping () -> Client?) {
        self.client = client
    }

    public func getString(_ key: String, _ defaultValue: String) -> String {
        switch scalar(key) {
        case .text(let text)?: return text
        case .flag(let flag)?: return flag ? "true" : "false"
        case .number(let number)?: return number.stringValue
        case .other(let object)?:
            guard JSONSerialization.isValidJSONObject(object), let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return defaultValue }
            return String(data: data, encoding: .utf8) ?? defaultValue
        case nil: return defaultValue
        }
    }

    public func getBoolean(_ key: String, _ defaultValue: Bool) -> Bool {
        switch scalar(key) {
        case .text(let text)?:
            switch text.lowercased() {
            case "true", "1", "yes": return true
            case "false", "0", "no": return false
            default: return defaultValue
            }
        case .flag(let flag)?: return flag
        case .number(let number)?: return number.doubleValue != 0
        default: return defaultValue
        }
    }

    public func getLong(_ key: String, _ defaultValue: Int64) -> Int64 {
        switch scalar(key) {
        case .text(let text)?: return Int64(text) ?? Double(text).flatMap { $0.isFinite && abs($0) < 9.2e18 ? Int64($0) : nil } ?? defaultValue
        case .number(let number)?: return number.int64Value
        default: return defaultValue
        }
    }

    public func getDouble(_ key: String, _ defaultValue: Double) -> Double {
        switch scalar(key) {
        case .text(let text)?: return Double(text) ?? defaultValue
        case .number(let number)?: return number.doubleValue
        default: return defaultValue
        }
    }

    /// A JSON parameter: a dictionary, an array or a plain value; a string holding JSON is parsed.
    public func getJson(_ key: String, _ defaultValue: Any? = nil) -> Any? {
        guard let value = stored(key) else { return defaultValue }
        if let text = value as? String {
            return (try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])) ?? defaultValue
        }
        return value
    }

    /// Every value the platform sent.
    public var all: [String: Any] { client()?.remoteConfig.all ?? [:] }

    /// Asks for the values now unless they were asked for within the interval; `completion` gets on the main thread
    /// whether the values changed.
    public func fetch(_ completion: ((Bool) -> Void)? = nil) {
        guard let client = client() else {
            if let completion = completion { DispatchQueue.main.async { completion(false) } }
            return
        }
        client.fetchRemoteConfig(force: false, completion)
    }

    /// Calls `listener` on the main thread with the changed keys every time new values arrive. Keep the result and
    /// call `cancel()` on it, or pass it to `removeListener`, to stop.
    @discardableResult
    public func addListener(_ listener: @escaping (Set<String>) -> Void) -> OneTraceObservation {
        let id = UUID()
        lock.lock()
        listeners[id] = listener
        lock.unlock()
        return OneTraceObservation { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            self.listeners[id] = nil
            self.lock.unlock()
        }
    }

    public func removeListener(_ observation: OneTraceObservation) {
        observation.cancel()
    }

    /// Called by the client on the main thread.
    func notify(_ keys: Set<String>) {
        lock.lock()
        let current = Array(listeners.values)
        lock.unlock()
        current.forEach { $0(keys) }
    }

    private func stored(_ key: String) -> Any? {
        guard let value = client()?.remoteConfig.value(key), !(value is NSNull) else { return nil }
        return value
    }

    private enum Scalar {
        case text(String)
        case flag(Bool)
        case number(NSNumber)
        case other(Any)
    }

    /// JSON values are `NSNumber` objects on Apple platforms (booleans too) and Swift values on Linux.
    private func scalar(_ key: String) -> Scalar? {
        guard let value = stored(key) else { return nil }
        if let text = value as? String { return .text(text) }
        if type(of: value) is NSNumber.Type, let number = value as? NSNumber {
            return Json.isBoolean(number) ? .flag(number.boolValue) : .number(number)
        }
        if let flag = value as? Bool { return .flag(flag) }
        if let number = value as? Int { return .number(NSNumber(value: number)) }
        if let number = value as? Double { return .number(NSNumber(value: number)) }
        return .other(value)
    }
}
