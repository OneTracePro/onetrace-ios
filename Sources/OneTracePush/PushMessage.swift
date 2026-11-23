import Foundation

/// A OneTrace push message read from the notification `userInfo`: the `cdp_*` keys of the platform contract, from APNs
/// (lists as arrays, `aps.category`) or from Firebase Messaging (lists as JSON strings).
///
/// The module is shared by the SDK and its Notification Service and Notification Content extensions. It is not a
/// product of the package: its API may change in any version.
public struct PushMessage {
    public enum Kind: String {
        case notification
        /// A Live Update of Android; nothing to show on iOS (Live Activities come through ActivityKit).
        case live
        /// The silent check of the installation: nothing is shown and nothing is reported.
        case ping
    }

    public static let tokenKey = "cdp_token"
    public static let urlKey = "cdp_url"
    public static let imageKey = "cdp_image"
    /// Set on the local copy that «Remind me later» schedules.
    public static let snoozedKey = "cdp_snoozed"

    public static let carouselCategory = "cdp_carousel"
    public static let timerCategory = "cdp_timer"
    public static let buttonsCategoryPrefix = "cdp_buttons_"

    public let kind: Kind
    /// The tracking token of the message: present on every OneTrace notification.
    public let token: String?
    public let url: URL?
    public let image: URL?
    public let title: String?
    public let body: String?
    /// `aps.category` set by the platform.
    public let category: String?
    /// Up to 3 buttons with known actions.
    public let buttons: [PushButton]
    /// Up to 10 cards; a carousel needs at least 2.
    public let carousel: [CarouselCard]
    public let timerEnd: Date?
    /// The local copy scheduled by «Remind me later».
    public let snoozed: Bool

    public init(_ userInfo: [AnyHashable: Any]) {
        let aps = userInfo["aps"] as? [String: Any] ?? [:]
        let alert = aps["alert"]

        token = Self.text(userInfo[Self.tokenKey])
        url = Self.link(userInfo[Self.urlKey])
        image = Self.link(userInfo[Self.imageKey])
        title = Self.text(userInfo["cdp_title"]) ?? Self.text((alert as? [String: Any])?["title"])
        body = Self.text(userInfo["cdp_body"]) ?? Self.text((alert as? [String: Any])?["body"]) ?? Self.text(alert)
        category = Self.text(aps["category"])
        buttons = Array(Self.list(userInfo["cdp_buttons"]).compactMap(PushButton.init(json:)).prefix(3))
        carousel = Array(Self.list(userInfo["cdp_carousel"]).compactMap(CarouselCard.init(json:)).prefix(10))
        timerEnd = Self.date(userInfo["cdp_timer_end"])
        snoozed = Self.text(userInfo[Self.snoozedKey]) == "1"

        // The silent check is only `cdp_kind: "ping"`: any other background push (`content-available`) belongs to the
        // app or another service.
        kind = Self.text(userInfo["cdp_kind"]).flatMap(Kind.init(rawValue:)) ?? .notification
    }

    public var isOneTrace: Bool { token != nil }

    /// The carousel is shown when at least two cards came.
    public var hasCarousel: Bool { carousel.count >= 2 }

    /// The notification category: `aps.category` of the platform, otherwise the same rule as the platform —
    /// `cdp_carousel`, `cdp_timer` (fixed: the Notification Content Extension lists them in its Info.plist) or
    /// `cdp_buttons_{hash8}` for the buttons of this message.
    public var categoryIdentifier: String? {
        if let category = category { return category }
        if hasCarousel { return Self.carouselCategory }
        if timerEnd != nil { return Self.timerCategory }
        if !buttons.isEmpty { return Self.buttonsCategoryPrefix + buttonsHash }
        return nil
    }

    /// 8 hex digits of the buttons (FNV-1a): the same buttons give the same category.
    public var buttonsHash: String {
        var hash: UInt32 = 2_166_136_261
        let text = buttons.map { [$0.id, $0.title, $0.action.rawValue, $0.url?.absoluteString ?? ""].joined(separator: "\u{1F}") }.joined(separator: "\u{1E}")
        for byte in text.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        let hex = String(hash, radix: 16)
        return String(repeating: "0", count: 8 - hex.count) + hex
    }

    /// The button the user pressed (`actionIdentifier` is its id, `b1`…`b3`).
    public func button(_ id: String) -> PushButton? {
        buttons.first { $0.id == id }
    }

    static func text(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func link(_ value: Any?) -> URL? {
        text(value).flatMap(URL.init(string:))
    }

    /// A list of objects: an array (APNs) or a JSON string (Firebase data, where every value is a string).
    static func list(_ value: Any?) -> [[String: Any]] {
        if let array = value as? [Any] { return array.compactMap { $0 as? [String: Any] } }
        if let text = value as? String, let data = text.data(using: .utf8),
           let array = (try? JSONSerialization.jsonObject(with: data)) as? [Any] {
            return array.compactMap { $0 as? [String: Any] }
        }
        return []
    }

    /// ISO 8601 (`2026-11-23T15:00:00Z`, with or without fractions) or UNIX seconds.
    static func date(_ value: Any?) -> Date? {
        if let seconds = value as? Double { return Date(timeIntervalSince1970: seconds) }
        if let seconds = value as? Int { return Date(timeIntervalSince1970: TimeInterval(seconds)) }
        guard let text = text(value) else { return nil }
        if let seconds = Double(text) { return Date(timeIntervalSince1970: seconds) }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}

/// A button of the message: `{"id": "b1", "title": "Buy", "action": "open_url", "url": "https://…"}`.
public struct PushButton: Equatable {
    public enum Action: String {
        case openURL = "open_url"
        case openApp = "open_app"
        /// Closes the notification; nothing is reported.
        case dismiss
        /// «Remind me later»: the SDK shows the same notification again after `snooze`.
        case snooze
    }

    public let id: String
    public let title: String
    public let action: Action
    public let url: URL?
    /// The delay of a snooze button.
    public let snooze: SnoozeDelay?

    public init(id: String, title: String, action: Action, url: URL? = nil, snooze: SnoozeDelay? = nil) {
        self.id = id
        self.title = title
        self.action = action
        self.url = url
        self.snooze = action == .snooze ? (snooze ?? .minutes(60)) : nil
    }

    init?(json: [String: Any]) {
        guard let id = PushMessage.text(json["id"]), Self.validId(id), let title = PushMessage.text(json["title"]) else { return nil }
        let url = PushMessage.link(json["url"])

        let action: Action
        switch PushMessage.text(json["action"]) {
        case "open_url"?, "url"?: action = url == nil ? .openApp : .openURL
        case "open_app"?, nil: action = .openApp
        case "dismiss"?: action = .dismiss
        case "snooze"?: action = .snooze
        default: return nil
        }

        self.init(id: id, title: title, action: action, url: action == .openURL ? url : nil, snooze: SnoozeDelay(json["snooze_minutes"]))
    }

    /// `^[A-Za-z0-9_-]{1,64}$`, as the platform checks it.
    static func validId(_ id: String) -> Bool {
        guard (1...64).contains(id.count) else { return false }
        return id.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0) || $0 == "_" || $0 == "-" }
    }
}

/// A carousel card: `{"image": "https://…", "title": "…", "body": "…", "url": "…"}`.
public struct CarouselCard: Equatable {
    public let image: URL?
    public let title: String?
    public let body: String?
    public let url: URL?

    public init(image: URL?, title: String?, body: String?, url: URL?) {
        self.image = image
        self.title = title
        self.body = body
        self.url = url
    }

    init?(json: [String: Any]) {
        let image = PushMessage.link(json["image"]) ?? PushMessage.link(json["image_url"])
        let title = PushMessage.text(json["title"])
        guard image != nil || title != nil else { return nil }
        self.init(image: image, title: title, body: PushMessage.text(json["body"]), url: PushMessage.link(json["url"]))
    }
}
