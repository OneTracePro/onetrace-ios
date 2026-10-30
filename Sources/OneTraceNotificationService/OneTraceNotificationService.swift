#if canImport(UserNotifications) && os(iOS)
import UserNotifications

/// The Notification Service Extension of OneTrace notifications: downloads the image (`cdp_image`) and attaches it.
/// Subclass it in your extension target, or call `OneTraceNotificationService.attachImage` from your own.
open class OneTraceNotificationService: UNNotificationServiceExtension {
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var content: UNMutableNotificationContent?

    override open func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        self.contentHandler = contentHandler
        let content = (request.content.mutableCopy() as? UNMutableNotificationContent) ?? UNMutableNotificationContent()
        self.content = content

        Self.attachImage(to: content) { contentHandler($0) }
    }

    override open func serviceExtensionTimeWillExpire() {
        if let contentHandler = contentHandler, let content = content {
            contentHandler(content)
        }
    }

    /// Attaches `cdp_image` to the notification; calls `done` with the content as is when there is no image.
    public static func attachImage(to content: UNMutableNotificationContent, done: @escaping (UNNotificationContent) -> Void) {
        guard let link = content.userInfo["cdp_image"] as? String, let url = URL(string: link) else {
            done(content)
            return
        }

        URLSession.shared.downloadTask(with: url) { location, response, _ in
            defer { done(content) }
            guard let location = location else { return }

            let suffix = (response?.mimeType == "image/png" || url.pathExtension.lowercased() == "png") ? "png" : "jpg"
            let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + suffix)

            if (try? FileManager.default.moveItem(at: location, to: file)) != nil,
               let attachment = try? UNNotificationAttachment(identifier: "image", url: file) {
                content.attachments = [attachment]
            }
        }.resume()
    }
}
#endif
