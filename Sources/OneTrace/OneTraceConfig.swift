import Foundation

/// SDK settings.
public struct OneTraceConfig {
    /// The project write key (`cdp_wk_…`) from the OneTrace admin panel.
    public var writeKey: String
    /// The address you open OneTrace at, for example `https://crm.example.com`; `/api/v1` is added automatically.
    public var host: String
    /// Send the queue once it has this many events.
    public var flushAt: Int
    /// Send the queue at least this often while the app is running.
    public var flushInterval: TimeInterval
    /// Events kept on disk while offline; the oldest are dropped beyond it.
    public var maxQueueSize: Int
    /// Send `app_installed`, `app_updated`, `app_opened` and `app_backgrounded`.
    public var trackLifecycle: Bool
    /// Open the link of a tapped push notification (`cdp_url`) automatically.
    public var openPushLinks: Bool
    /// Print what the SDK does to the console.
    public var debug: Bool
    /// Remote Config values are asked for at most this often (seconds); `identify` and `reset` ask at once.
    public var remoteConfigMinFetchInterval: TimeInterval
    /// The App Group shared with the Notification Content Extension: a tapped carousel card then opens its own link.
    public var appGroup: String?

    public init(
        writeKey: String,
        host: String,
        flushAt: Int = 20,
        flushInterval: TimeInterval = 30,
        maxQueueSize: Int = 1000,
        trackLifecycle: Bool = true,
        openPushLinks: Bool = true,
        debug: Bool = false,
        remoteConfigMinFetchInterval: TimeInterval = 3600,
        appGroup: String? = nil
    ) {
        self.writeKey = writeKey
        self.host = host
        self.flushAt = flushAt
        self.flushInterval = flushInterval
        self.maxQueueSize = maxQueueSize
        self.trackLifecycle = trackLifecycle
        self.openPushLinks = openPushLinks
        self.debug = debug
        self.remoteConfigMinFetchInterval = remoteConfigMinFetchInterval
        self.appGroup = appGroup
    }

    var apiURL: String {
        var base = host.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        if base.hasSuffix("/api/v1") { base.removeLast("/api/v1".count) }
        return base + "/api/v1"
    }
}
