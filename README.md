# OneTrace.pro for iOS

[![CI](https://github.com/OneTracePro/onetrace-ios/actions/workflows/ci.yml/badge.svg)](https://github.com/OneTracePro/onetrace-ios/actions/workflows/ci.yml)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

The iOS SDK of [OneTrace.pro](https://onetrace.pro), the customer data platform: events and screens of your app users in the same profiles as your website, CRM and stores — for segments, journeys, predictions and analytics — and push notifications.

- Swift, iOS 13+. No dependencies: Foundation, UIKit and UserNotifications only.
- Events are queued on disk and sent in batches: nothing is lost offline or on a restart.
- Push notifications through APNs with your `.p8` key, or through Firebase Messaging if the app already uses it.

## Installation

Swift Package Manager: in Xcode **File → Add Package Dependencies…** with `https://github.com/OneTracePro/onetrace-ios`, or in `Package.swift`:

```swift
.package(url: "https://github.com/OneTracePro/onetrace-ios", from: "1.1.0")
```

Add the `OneTrace` product to the app target, and `OneTraceNotificationService` to a Notification Service Extension if you want images in notifications.

## Quick start

In `application(_:didFinishLaunchingWithOptions:)`:

```swift
import OneTrace

OneTrace.setup(OneTraceConfig(
    writeKey: "cdp_wk_…",                 // Settings → API keys: a write key
    host: "https://crm.example.com"      // the address you open OneTrace at
))
```

Then, anywhere:

```swift
OneTrace.screen("Product", ["product_id": "SKU-1"])
OneTrace.track("add_to_cart", ["product_id": "SKU-1", "price": 49.9])
OneTrace.identify("u-42", traits: ["email": "anna@example.com"])  // after sign-in
OneTrace.reset()                                                  // after sign-out
```

Use the same event names and `product_id` values as on your website — then recommendations, abandoned cart journeys and the reports work across the website and the app. See the [e-commerce events](https://onetrace.pro/en/docs/api).

The SDK sends `app_installed`, `app_updated`, `app_opened` and `app_backgrounded` itself, with the app version, device model, iOS version, language and time zone in the context of every event.

## Signed user ids

The write key ships inside the app, so anyone could call `identify` with someone else's user id and receive that customer's in-app messages and push. Sign the user id on your server to prove it belongs to the signed-in user. When the project requires the signature (**Website → Connection → Server**), a user id without a valid one is ignored: events stay with the anonymous id, and the installation is not registered for that user.

1. Create the signing key on the **Website → Connection → Server** tab and keep it on your server only — never put it into the app.
2. After sign-in, your server returns the signature with the session: HMAC-SHA256 of the user id with the signing key, in hex.

   ```php
   $userHash = hash_hmac('sha256', $userId, getenv('CDP_IDENTITY_KEY'));
   ```

   ```js
   const userHash = crypto.createHmac('sha256', process.env.CDP_IDENTITY_KEY).update(userId).digest('hex');
   ```

3. Pass it to `identify` (and to `alias`):

   ```swift
   OneTrace.identify(session.userId, traits: ["email": session.email], userHash: session.userHash)
   ```

The SDK keeps the signature with the user id and sends it as `userHash` with every event and the installation registration. A later `identify` of the same user without a signature keeps the stored one; another user id or `reset()` clears it. After the key is changed, the previous one is accepted for another 24 hours: return signatures with the new key from your server before then.

## Push notifications

1. In the target **Signing & Capabilities** add **Push Notifications**.
2. Make OneTrace the notification delegate and register for push:

   ```swift
   UNUserNotificationCenter.current().delegate = OneTraceNotificationDelegate.shared
   UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in
       OneTrace.notificationPermissionChanged()
   }
   application.registerForRemoteNotifications()
   ```

3. Pass the device token:

   ```swift
   func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
       OneTrace.setPushToken(deviceToken)
   }
   ```

4. In OneTrace add the **Mobile push** integration with your bundle id and an APNs key: Apple Developer → Certificates, Identifiers & Profiles → Keys, a key with Apple Push Notifications service (the `.p8` file, its Key ID and your Team ID). Builds from Xcode use the **sandbox** environment, TestFlight and the App Store — **production**.

`OneTraceNotificationDelegate` shows OneTrace notifications while the app is open and reports them as delivered; a tap reports the open and opens the notification link (`myapp://…` or `https://…`). If you have your own delegate, set it as `OneTraceNotificationDelegate.shared.next` — notifications from other senders go to it. Or call `OneTrace.handleNotificationOpen(userInfo)` and `OneTrace.handleNotificationReceived(userInfo)` from your delegate.

If the app gets push through Firebase Messaging, pass the FCM token instead: `OneTrace.setPushToken(fcmToken, provider: .fcm)`; the integration then needs the Firebase service account.

**Images.** Add a Notification Service Extension target with the `OneTraceNotificationService` product and make its principal class a subclass:

```swift
import OneTraceNotificationService

class NotificationService: OneTraceNotificationService {}
```

## How it works

- Every installation has a random id; while push can be sent, it is the `mobile_push` identity of the profile, and the profile is reachable by the **Mobile push** channel in journeys and campaigns.
- `identify` and `reset` re-register the installation: after a sign-out push goes to the next user, the profiles are not merged.
- Events are sent when 20 are queued, every 30 seconds and when the app goes to the background; up to 1,000 are kept on disk.

## Tests

`swift test` runs the core tests (macOS or Linux); CI also builds every target for the iOS simulator. Against a real project:

```bash
ONETRACE_URL=https://crm.example.com ONETRACE_KEY=cdp_wk_… swift test --filter LiveTests
```

## License

MIT
