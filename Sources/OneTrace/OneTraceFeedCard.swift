import Foundation

/// A card of the message feed: a personal offer, news, reminder or promo code that stays in the app until it expires or
/// the user dismisses it (unlike in-app messages, which are shown once).
public struct OneTraceFeedCard: Equatable, Sendable {
    public enum Layout: String, Sendable {
        /// The image on the left of the text.
        case classic
        /// The image above the text.
        case captioned
        /// The image only.
        case banner
    }

    /// Identifies the card in the reports to OneTrace.
    public let token: String
    public let layout: Layout
    public let title: String
    public let body: String?
    /// An `https` image.
    public let imageURL: URL?
    /// The button label; nil when the whole card is the link.
    public let buttonText: String?
    /// A web page or a deep link of the app; `javascript:` and `data:` links are dropped.
    public let buttonURL: URL?
    /// Shown above the other cards.
    public let pinned: Bool
    /// Already shown to the user: not counted as unread.
    public internal(set) var read: Bool
    public let createdAt: Date?
    public let expiresAt: Date?

    /// A tap anywhere on the card opens `buttonURL`: a card without a button label, or a banner.
    public var opensOnTap: Bool { buttonURL != nil && (buttonText == nil || layout == .banner) }

    /// A card from the `GET /feed` answer; nil without a token.
    init?(json: [String: Any]) {
        guard let token = json["token"] as? String, !token.isEmpty else { return nil }

        self.token = token
        layout = (json["layout"] as? String).flatMap(Layout.init(rawValue:)) ?? .classic
        title = json["title"] as? String ?? ""
        body = Self.text(json["body"])
        imageURL = Self.text(json["image_url"]).flatMap(URL.init(string:)).flatMap { ["http", "https"].contains($0.scheme?.lowercased() ?? "") ? $0 : nil }
        buttonText = Self.text(json["button_text"])
        buttonURL = Self.link(json["button_url"])
        pinned = json["pinned"] as? Bool ?? false
        read = json["read"] as? Bool ?? false
        createdAt = Self.date(json["created_at"])
        expiresAt = Self.date(json["expires_at"])
    }

    private static func text(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : text
    }

    /// A link with a scheme the app can open: `https://…` or `myapp://…`, never script or inline data.
    private static func link(_ value: Any?) -> URL? {
        guard let text = text(value)?.trimmingCharacters(in: .whitespacesAndNewlines), let url = URL(string: text),
              let scheme = url.scheme?.lowercased(), !["javascript", "data", "vbscript", "file"].contains(scheme) else { return nil }
        return url
    }

    /// ISO 8601 as the platform writes it (`2026-11-09T10:00:00+00:00`), with or without fractions of a second.
    private static func date(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
    }
}

/// A subscription to feed changes; `cancel()` stops it.
public final class OneTraceObservation {
    private let lock = NSLock()
    private var onCancel: (() -> Void)?

    init(_ onCancel: @escaping () -> Void) {
        self.onCancel = onCancel
    }

    public func cancel() {
        lock.lock()
        let cancel = onCancel
        onCancel = nil
        lock.unlock()
        cancel?()
    }
}
