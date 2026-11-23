#if canImport(UserNotifications) && os(iOS)
import Foundation
import OneTracePush
import UserNotifications

/// The Notification Service Extension of OneTrace notifications: registers the category with the buttons of the
/// message, downloads the image (`cdp_image`) and the carousel pictures and attaches them, adds the end of the timer to
/// the text («until 18:00»). Subclass it in your extension target, or call `OneTraceNotificationService.prepare` from
/// your own.
open class OneTraceNotificationService: UNNotificationServiceExtension {
    private let lock = NSLock()
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var content: UNMutableNotificationContent?

    /// Adds the end of the timer to the notification text. Without `OneTraceNotificationContent` it is the only place
    /// the timer is seen; override with false if your content extension shows it and the text should stay as is.
    open var appendsTimerEnd: Bool { true }

    override open func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        let content = (request.content.mutableCopy() as? UNMutableNotificationContent) ?? UNMutableNotificationContent()
        lock.lock()
        self.contentHandler = contentHandler
        self.content = content
        lock.unlock()

        Self.prepare(content, appendTimerEnd: appendsTimerEnd) { [weak self] in self?.finish() }
    }

    override open func serviceExtensionTimeWillExpire() {
        finish()
    }

    /// Delivers the content once: when everything is ready, or when the time of the extension runs out.
    private func finish() {
        lock.lock()
        let handler = contentHandler
        contentHandler = nil
        let content = self.content
        lock.unlock()
        if let handler = handler, let content = content { handler(content) }
    }

    /// Prepares a OneTrace notification: the category with its buttons, the end of the timer, the pictures. `done` runs
    /// when it is ready; other notifications are left as they are.
    public static func prepare(_ content: UNMutableNotificationContent, appendTimerEnd: Bool = true, done: @escaping () -> Void) {
        let message = PushMessage(content.userInfo)
        guard message.isOneTrace, message.kind == .notification else {
            done()
            return
        }

        if appendTimerEnd, let end = message.timerEnd {
            content.body = TimerText.appending(to: content.body, end: end)
        }

        let group = DispatchGroup()

        if let category = message.categoryIdentifier {
            content.categoryIdentifier = category
            group.enter()
            NotificationCategories.register(category, buttons: message.buttons) { group.leave() }
        }

        var pictures: [Picture] = []
        if message.hasCarousel {
            for (index, card) in message.carousel.enumerated() {
                if let image = card.image { pictures.append(Picture(id: "card\(index)", url: image)) }
            }
        } else if let image = message.image {
            pictures.append(Picture(id: "image", url: image))
        }

        let collected = Attachments()
        for picture in pictures {
            group.enter()
            ImageDownload.attachment(picture.url, id: picture.id) { attachment in
                if let attachment = attachment { collected.add(attachment) }
                group.leave()
            }
        }

        let order = pictures.map(\.id)
        group.notify(queue: .global()) {
            // In the order of the cards: the first one is the thumbnail of the collapsed notification.
            content.attachments = collected.sorted(by: order)
            done()
        }
    }

    /// Attaches `cdp_image` to the notification; calls `done` with the content as is when there is no image.
    public static func attachImage(to content: UNMutableNotificationContent, done: @escaping (UNNotificationContent) -> Void) {
        guard let link = content.userInfo["cdp_image"] as? String, let url = URL(string: link) else {
            done(content)
            return
        }

        ImageDownload.attachment(url, id: "image") { attachment in
            if let attachment = attachment { content.attachments = [attachment] }
            done(content)
        }
    }
}

private struct Picture {
    let id: String
    let url: URL
}

/// Attachments downloaded in parallel.
private final class Attachments {
    private let lock = NSLock()
    private var items: [String: UNNotificationAttachment] = [:]

    func add(_ attachment: UNNotificationAttachment) {
        lock.lock()
        items[attachment.identifier] = attachment
        lock.unlock()
    }

    func sorted(by order: [String]) -> [UNNotificationAttachment] {
        lock.lock()
        defer { lock.unlock() }
        return order.compactMap { items[$0] }
    }
}

/// Buttons of a message: a category registered before the notification is shown. iOS keeps one set of categories
/// for the app, so the other categories stay; of the `cdp_buttons_*` ones only the newest 30 are kept.
enum NotificationCategories {
    private static let recentKey = "pro.onetrace.button_categories"
    private static let keep = 30

    static func register(_ identifier: String, buttons: [PushButton], then: @escaping () -> Void) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationCategories { existing in
            var categories = existing.filter { $0.identifier != identifier }

            if identifier.hasPrefix(PushMessage.buttonsCategoryPrefix) {
                var recent = UserDefaults.standard.stringArray(forKey: NotificationCategories.recentKey) ?? []
                recent.removeAll { $0 == identifier }
                recent.append(identifier)
                let dropped = Set(recent.dropLast(NotificationCategories.keep))
                recent = Array(recent.suffix(NotificationCategories.keep))
                UserDefaults.standard.set(recent, forKey: NotificationCategories.recentKey)
                categories = categories.filter { !dropped.contains($0.identifier) }
            }

            let actions = buttons.map { button -> UNNotificationAction in
                // Links and «open the app» bring the app forward; «close» and «remind me later» are handled in the background.
                let options: UNNotificationActionOptions = button.action == .openURL || button.action == .openApp ? [.foreground] : []
                return UNNotificationAction(identifier: button.id, title: button.title, options: options)
            }
            categories.insert(UNNotificationCategory(identifier: identifier, actions: actions, intentIdentifiers: [], options: []))
            center.setNotificationCategories(categories)
            // Reading them back makes sure they are applied before the notification is shown.
            center.getNotificationCategories { _ in then() }
        }
    }
}

/// A picture for a notification: at most 10 seconds and 1 MB, PNG, GIF or JPEG.
enum ImageDownload {
    static let maxBytes = 1_048_576

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 10
        return URLSession(configuration: configuration)
    }()

    static func attachment(_ url: URL, id: String, done: @escaping (UNNotificationAttachment?) -> Void) {
        session.downloadTask(with: url) { location, response, _ in
            guard let location = location else {
                done(nil)
                return
            }

            let attributes = try? FileManager.default.attributesOfItem(atPath: location.path)
            let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
            guard size > 0, size <= ImageDownload.maxBytes else {
                done(nil)
                return
            }

            let mime = response?.mimeType ?? ""
            let suffix: String
            if mime == "image/png" || url.pathExtension.lowercased() == "png" {
                suffix = "png"
            } else if mime == "image/gif" || url.pathExtension.lowercased() == "gif" {
                suffix = "gif"
            } else {
                suffix = "jpg"
            }
            let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + suffix)

            guard (try? FileManager.default.moveItem(at: location, to: file)) != nil else {
                done(nil)
                return
            }
            done(try? UNNotificationAttachment(identifier: id, url: file))
        }.resume()
    }
}
#endif
