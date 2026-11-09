import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// OneTrace.pro for iOS: events, screens and identities of app users, installations for mobile push.
///
/// Call `OneTrace.setup(_:)` once in `application(_:didFinishLaunchingWithOptions:)`; every other call is safe from any
/// thread and does nothing before it.
public enum OneTrace {
    /// Push provider of the token passed to `setPushToken`.
    public enum PushProvider: String {
        case apns
        case fcm
    }

    private static let lock = NSLock()
    private static var client: Client?
    private static var wrapper: (name: String, version: String)?
    #if canImport(UIKit) && !os(watchOS)
    private static var lifecycle: AppLifecycle?
    #endif

    public static func setup(_ config: OneTraceConfig) {
        lock.lock()
        defer { lock.unlock() }
        guard client == nil else { return }

        let storage = Storage()
        let device = DeviceContext(installationId: storage.installationId)
        device.wrapper = wrapper
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        let created = Client(
            config: config,
            storage: storage,
            events: EventQueue(file: directory.appendingPathComponent("onetrace/queue.jsonl"), maxSize: config.maxQueueSize),
            transport: URLSessionTransport(apiURL: config.apiURL, writeKey: config.writeKey, userAgent: "onetrace-ios/\(DeviceContext.sdkVersion) (\(device.bundleId))"),
            device: device
        )
        client = created

        #if canImport(UIKit) && !os(watchOS)
        let permissions = NotificationPermission()
        let inApp = InAppPresenter(openLinks: config.openPushLinks) { [weak created] token, event, url in created?.reportInApp(token, event, url) }
        created.notificationsEnabled = { permissions.enabled }
        created.presenter = { inApp.present($0) }
        lifecycle = AppLifecycle(client: created, permissions: permissions, inApp: inApp)
        #endif

        created.appLaunched()
        created.start()
        #if canImport(UIKit) && !os(watchOS)
        lifecycle?.attach()
        #endif
    }

    /// Your own event, for example `track("order_completed", ["order_id": "1001", "amount": 1250.5])`.
    public static func track(_ event: String, _ properties: [String: Any?] = [:]) {
        current?.track(event, properties)
    }

    /// A screen of the app: the `$screen` event with the screen name.
    public static func screen(_ name: String, _ properties: [String: Any?] = [:]) {
        current?.screen(name, properties)
    }

    /// The user signed in or updated their data. Pass nil as the user id to update traits of the current visitor.
    ///
    /// `userHash` is the signature of the user id: HMAC-SHA256 of `userId` with the project's signing key, in hex.
    /// Your server computes it after sign-in and returns it to the app; never put the signing key into the app. When
    /// the project requires the signature, a user id without it is ignored. The SDK keeps it with the user id and sends
    /// it with every event and the installation; a later `identify` of the same user without it keeps the stored one.
    public static func identify(_ userId: String?, traits: [String: Any?] = [:], userHash: String? = nil) {
        current?.identify(userId, traits, userHash)
    }

    /// Links the current anonymous visitor to a new user id; `userHash` is its signature, as in `identify`.
    public static func alias(_ userId: String, userHash: String? = nil) {
        current?.alias(userId, userHash)
    }

    /// The user signed out: a new anonymous id, and the installation leaves the previous user's profile.
    public static func reset() {
        current?.reset()
    }

    /// Sends queued events now instead of waiting for the next batch.
    public static func flush() {
        current?.flush()
    }

    /// The APNs device token from `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`.
    public static func setPushToken(_ deviceToken: Data) {
        setPushToken(deviceToken.map { String(format: "%02x", $0) }.joined(), provider: .apns)
    }

    /// A push token as a string: an FCM token if the app uses Firebase Messaging. Nil removes it.
    public static func setPushToken(_ token: String?, provider: PushProvider) {
        #if canImport(UIKit) && !os(watchOS)
        lifecycle?.permissions.refresh { current?.setPushToken(token, provider: provider.rawValue) }
        #else
        current?.setPushToken(token, provider: provider.rawValue)
        #endif
    }

    /// Holds in-app messages back while true, for example during checkout; they are shown after it is set back to false
    /// and the app opens again or tracks their trigger event.
    public static func pauseInAppMessages(_ paused: Bool) {
        current?.queue.async { current?.inAppPaused = paused }
    }

    /// Asks OneTrace for in-app messages now; the SDK also does it when the app opens and after sending events.
    public static func fetchInAppMessages() {
        current?.fetchInApp()
    }

    /// Loads the message feed of this user: pinned cards first, then the newest, up to 50. `completion` runs on the main
    /// thread; on a network error it gets the cards loaded before. Once the app uses the feed, the SDK also refreshes
    /// it when the app opens and after `reset()`.
    public static func fetchFeed(_ completion: @escaping ([OneTraceFeedCard]) -> Void) {
        guard let client = current else {
            DispatchQueue.main.async { completion([]) }
            return
        }
        client.fetchFeed(completion)
    }

    /// Loads the message feed, as `fetchFeed(_:)`.
    public static func fetchFeed() async -> [OneTraceFeedCard] {
        await withCheckedContinuation { continuation in
            fetchFeed { continuation.resume(returning: $0) }
        }
    }

    /// The feed cards loaded last.
    public static var feedCards: [OneTraceFeedCard] { current?.feed.currentCards ?? [] }

    /// Cards not shown to the user yet, for a badge.
    public static var feedUnreadCount: Int { current?.feed.currentUnread ?? 0 }

    /// Calls `handler` on the main thread with the unread count now and every time it changes; loads the feed if it
    /// was not loaded yet. Keep the result and call `cancel()` on it to stop.
    @discardableResult
    public static func observeFeedUnread(_ handler: @escaping (Int) -> Void) -> OneTraceObservation {
        current?.observeFeedUnread(handler) ?? OneTraceObservation {}
    }

    /// Calls `handler` on the main thread with the feed cards now and every time they change (loaded, shown, dismissed),
    /// for your own feed screen; it does not load the feed — call `fetchFeed` when the screen opens.
    @discardableResult
    public static func observeFeed(_ handler: @escaping ([OneTraceFeedCard]) -> Void) -> OneTraceObservation {
        current?.observeFeed(handler) ?? OneTraceObservation {}
    }

    /// The card is on screen (at least half of it, in the open feed): it becomes read, the message delivered and
    /// opened. Reported once; `OneTraceFeedViewController` calls it for you.
    public static func feedCardShown(_ card: OneTraceFeedCard) {
        current?.reportFeed(card.token, "shown", nil)
    }

    /// The user tapped the card button, or the card without a button: reports the click and, with `openPushLinks`,
    /// opens `buttonURL` as push links are opened.
    public static func feedCardClicked(_ card: OneTraceFeedCard) {
        guard let client = current else { return }
        client.reportFeed(card.token, "clicked", card.buttonURL?.absoluteString)

        #if canImport(UIKit) && !os(watchOS)
        if client.config.openPushLinks, let url = card.buttonURL {
            DispatchQueue.main.async { UIApplication.shared.open(url) }
        }
        #endif
    }

    /// The user removed the card: it leaves the feed and is not returned again.
    public static func feedCardDismissed(_ card: OneTraceFeedCard) {
        current?.reportFeed(card.token, "dismissed", nil)
    }

    /// Call after the user answered the notification permission prompt.
    public static func notificationPermissionChanged() {
        #if canImport(UIKit) && !os(watchOS)
        lifecycle?.permissions.refresh { current?.refreshRegistration() }
        #else
        current?.refreshRegistration()
        #endif
    }

    /// True when the notification came from OneTrace.
    public static func isOneTraceNotification(_ userInfo: [AnyHashable: Any]) -> Bool {
        userInfo[Client.pushToken] is String
    }

    /// A tap on a notification (`userNotificationCenter(_:didReceive:withCompletionHandler:)`): reports the open and,
    /// with `openPushLinks`, opens its link. `OneTraceNotificationDelegate` calls it for you.
    ///
    /// - Returns: false when the notification is not from OneTrace.
    @discardableResult
    public static func handleNotificationOpen(_ userInfo: [AnyHashable: Any]) -> Bool {
        guard let client = current, isOneTraceNotification(userInfo) else { return false }
        let url = client.notificationOpened(userInfo)

        #if canImport(UIKit) && !os(watchOS) && !targetEnvironment(macCatalyst)
        if client.config.openPushLinks, let url = url {
            DispatchQueue.main.async { UIApplication.shared.open(url) }
        }
        #endif

        return true
    }

    /// A OneTrace notification reached the app in the foreground: the message becomes delivered.
    public static func handleNotificationReceived(_ userInfo: [AnyHashable: Any]) {
        current?.notificationReceived(userInfo)
    }

    public static var anonymousId: String? { current?.anonymousId }

    public static var userId: String? { current?.userId }

    /// The installation id: the `mobile_push` identity of the profile while push can be sent.
    public static var installationId: String? { current?.installationId }

    /// For the Flutter and React Native wrappers, before `setup`: report the wrapper as the library — `flutter` becomes
    /// `onetrace-flutter` in the event context and `flutter 1.0.0` in the installation.
    public static func setWrapper(name: String, version: String) {
        lock.lock()
        wrapper = (name, version)
        client?.device.wrapper = wrapper
        lock.unlock()
    }

    private static var current: Client? {
        lock.lock()
        defer { lock.unlock() }
        return client
    }
}
