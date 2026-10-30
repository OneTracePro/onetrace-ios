#if canImport(UserNotifications) && !os(watchOS)
import UserNotifications

/// A `UNUserNotificationCenter` delegate for OneTrace notifications: shows them in the foreground and reports them as
/// delivered, reports taps and opens their links. Other notifications go to `next`, your own delegate.
///
/// ```swift
/// OneTraceNotificationDelegate.shared.next = self   // optional
/// UNUserNotificationCenter.current().delegate = OneTraceNotificationDelegate.shared
/// ```
public final class OneTraceNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    public static let shared = OneTraceNotificationDelegate()

    public weak var next: UNUserNotificationCenterDelegate?

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let userInfo = notification.request.content.userInfo

        guard OneTrace.isOneTraceNotification(userInfo) else {
            if let next = next, next.responds(to: #selector(UNUserNotificationCenterDelegate.userNotificationCenter(_:willPresent:withCompletionHandler:))) {
                next.userNotificationCenter?(center, willPresent: notification, withCompletionHandler: completionHandler)
            } else {
                completionHandler([])
            }
            return
        }

        OneTrace.handleNotificationReceived(userInfo)
        if #available(iOS 14.0, *) {
            completionHandler([.banner, .list, .sound])
        } else {
            completionHandler([.alert, .sound])
        }
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo

        if response.actionIdentifier == UNNotificationDefaultActionIdentifier, OneTrace.handleNotificationOpen(userInfo) {
            completionHandler()
            return
        }

        if let next = next, next.responds(to: #selector(UNUserNotificationCenterDelegate.userNotificationCenter(_:didReceive:withCompletionHandler:))) {
            next.userNotificationCenter?(center, didReceive: response, withCompletionHandler: completionHandler)
        } else {
            completionHandler()
        }
    }
}
#endif
