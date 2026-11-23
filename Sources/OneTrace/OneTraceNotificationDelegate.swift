#if canImport(UserNotifications) && !os(watchOS)
import OneTracePush
import UserNotifications

/// A `UNUserNotificationCenter` delegate for OneTrace notifications: shows them in the foreground and reports them as
/// delivered, reports taps and button presses and opens their links, shows «Remind me later» again after its delay.
/// Other notifications go to `next`, your own delegate.
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
        let content = response.notification.request.content
        let userInfo = content.userInfo
        let action = response.actionIdentifier

        // A tap, or a button of the message (`b1`…`b3`); a swipe away and buttons of other categories go on.
        if OneTrace.isOneTraceNotification(userInfo),
           action == UNNotificationDefaultActionIdentifier || PushMessage(userInfo).button(action) != nil {
            OneTrace.handleOpen(userInfo, actionIdentifier: action == UNNotificationDefaultActionIdentifier ? nil : action, original: content, done: completionHandler)
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
