#if canImport(UserNotifications) && !os(watchOS)
import Foundation
import OneTracePush
import UserNotifications
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// «Remind me later»: the phone itself shows a copy of the notification after the delay of the button, even offline;
/// the platform does not send it again. The copy has the same `cdp_token`, so its open counts for the same message.
enum PushSnooze {
    static func schedule(userInfo: [AnyHashable: Any], original: AnyObject?, delay: SnoozeDelay, done: (() -> Void)?) {
        let message = PushMessage(userInfo)
        let content = UNMutableNotificationContent()
        if let original = original as? UNNotificationContent {
            content.title = original.title
            content.subtitle = original.subtitle
            content.body = original.body
            content.categoryIdentifier = original.categoryIdentifier
            content.threadIdentifier = original.threadIdentifier
        } else {
            content.title = message.title ?? ""
            content.body = message.body ?? ""
            content.categoryIdentifier = message.categoryIdentifier ?? ""
        }
        content.sound = .default

        var info: [AnyHashable: Any] = [:]
        for (key, value) in userInfo {
            if let key = key as? String, let safe = propertyList(value) { info[key] = safe }
        }
        info[PushMessage.snoozedKey] = "1"
        content.userInfo = info

        let trigger: UNNotificationTrigger
        switch delay.trigger() {
        case .interval(let seconds):
            trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, seconds), repeats: false)
        case .calendar(let components):
            trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        }

        // Attachments of the delivered notification belong to the system: the picture is downloaded again.
        attach(message.image ?? message.carousel.first?.image, to: content) {
            let request = UNNotificationRequest(identifier: "onetrace.snooze." + UUID().uuidString, content: content, trigger: trigger)
            UNUserNotificationCenter.current().add(request) { _ in done?() }
        }
    }

    private static func attach(_ url: URL?, to content: UNMutableNotificationContent, then: @escaping () -> Void) {
        guard let url = url else {
            then()
            return
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = 10
        URLSession(configuration: configuration).downloadTask(with: url) { location, response, _ in
            defer { then() }
            guard let location = location else { return }
            let suffix = (response?.mimeType == "image/png" || url.pathExtension.lowercased() == "png") ? "png" : "jpg"
            let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + suffix)
            if (try? FileManager.default.moveItem(at: location, to: file)) != nil,
               let attachment = try? UNNotificationAttachment(identifier: "image", url: file) {
                content.attachments = [attachment]
            }
        }.resume()
    }

    /// The notification `userInfo` must be a property list: JSON nulls and other objects are left out.
    private static func propertyList(_ value: Any) -> Any? {
        switch value {
        case let text as String: return text
        case let number as NSNumber: return number
        case let date as Date: return date
        case let data as Data: return data
        case let list as [Any]: return list.compactMap { propertyList($0) }
        case let object as [String: Any]:
            var safe: [String: Any] = [:]
            for (key, item) in object {
                if let item = propertyList(item) { safe[key] = item }
            }
            return safe
        default: return nil
        }
    }
}
#endif
