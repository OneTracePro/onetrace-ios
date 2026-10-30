#if canImport(UIKit) && !os(watchOS)
import UIKit
import UserNotifications

/// Whether the user allows notifications, read from `UNUserNotificationCenter` and cached for registrations.
final class NotificationPermission {
    private(set) var enabled = false

    func refresh(_ then: @escaping () -> Void) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            var allowed = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
            if #available(iOS 14.0, *) { allowed = allowed || settings.authorizationStatus == .ephemeral }
            self.enabled = allowed
            then()
        }
    }
}

/// Foreground and background from `UIApplication` notifications: `app_opened`, `app_backgrounded`, a flush in the
/// background and a fresh registration when the notification permission may have changed in the settings.
final class AppLifecycle {
    let permissions: NotificationPermission
    private let client: Client
    private let inApp: InAppPresenter
    private var observers: [NSObjectProtocol] = []

    init(client: Client, permissions: NotificationPermission, inApp: InAppPresenter) {
        self.client = client
        self.permissions = permissions
        self.inApp = inApp
    }

    func attach() {
        let center = NotificationCenter.default
        permissions.refresh { [client] in client.refreshRegistration() }
        client.appForeground(fromBackground: false)

        observers.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: nil) { [weak self] _ in
            guard let self = self else { return }
            self.permissions.refresh { self.client.appForeground(fromBackground: true) }
        })
        observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.inApp.showNext()
        })
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            var task = UIBackgroundTaskIdentifier.invalid
            task = UIApplication.shared.beginBackgroundTask { UIApplication.shared.endBackgroundTask(task) }
            self.client.appBackground {
                DispatchQueue.main.async { UIApplication.shared.endBackgroundTask(task) }
            }
        })
    }
}
#endif
