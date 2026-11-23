import Foundation

/// The carousel card the user tapped in the Notification Content Extension, handed to the app through a shared App
/// Group: the app then reports the open with the card link and opens it. Without an App Group the message link opens.
public enum CarouselSelection {
    static let key = "pro.onetrace.carousel.selection"
    /// A selection older than this is not the tap that opened the app.
    static let lifetime: TimeInterval = 300

    public static func save(token: String, url: URL, in defaults: UserDefaults, now: Date = Date()) {
        defaults.set(["token": token, "url": url.absoluteString, "at": now.timeIntervalSince1970], forKey: key)
    }

    /// The link of the card tapped in the notification with this token; the selection is used once.
    public static func take(token: String, from defaults: UserDefaults, now: Date = Date()) -> URL? {
        guard let saved = defaults.dictionary(forKey: key) else { return nil }
        guard saved["token"] as? String == token else { return nil }
        defaults.removeObject(forKey: key)

        let at = (saved["at"] as? Double) ?? 0
        guard abs(now.timeIntervalSince1970 - at) <= lifetime, let link = saved["url"] as? String else { return nil }
        return URL(string: link)
    }
}
