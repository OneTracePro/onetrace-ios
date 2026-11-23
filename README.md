# OneTrace.pro for iOS

[![CI](https://github.com/OneTracePro/onetrace-ios/actions/workflows/ci.yml/badge.svg)](https://github.com/OneTracePro/onetrace-ios/actions/workflows/ci.yml)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

The iOS SDK of [OneTrace.pro](https://onetrace.pro), the customer data platform: events and screens of your app users in the same profiles as your website, CRM and stores — for segments, journeys, predictions and analytics — and push notifications.

- Swift, iOS 13+. No dependencies: Foundation, UIKit and UserNotifications only (and SwiftUI for the feed view).
- Events are queued on disk and sent in batches: nothing is lost offline or on a restart.
- Push notifications through APNs with your `.p8` key, or through Firebase Messaging if the app already uses it: images, a carousel, a countdown and up to three buttons, including «Remind me later».
- Live Activities of order and delivery statuses and countdowns, updated by the platform through APNs.
- Geofences (a separate product): entering, leaving and staying in your zones as events, without sending coordinates.
- Remote Config: app parameters with values by segment, without a new app version.
- In-app messages and a message feed with a ready-made screen for UIKit and SwiftUI.

## Installation

Swift Package Manager: in Xcode **File → Add Package Dependencies…** with `https://github.com/OneTracePro/onetrace-ios`, or in `Package.swift`:

```swift
.package(url: "https://github.com/OneTracePro/onetrace-ios", from: "1.2.0")
```

Add the `OneTrace` product to the app target; `OneTraceNotificationService` to a Notification Service Extension (images, buttons, the timer end in the text), `OneTraceNotificationContent` to a Notification Content Extension (the carousel and the countdown of an expanded notification), and `OneTraceLocation` to the app target if you use geofences.

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

The extension also registers the buttons of the message (a notification category `cdp_buttons_…`; with a carousel or a timer — under the fixed categories `cdp_carousel` and `cdp_timer`) and adds the end of the timer to the text by the phone clock and language: «Sale on everything · until 18:00». Without the extension, or with an older SDK, the notification has no buttons and a tap opens the message link.

### Buttons

`OneTraceNotificationDelegate` handles them: «Open link» reports the open with the button and opens its link, «Open the app» brings the app forward, «Close» removes the notification without reports, «Remind me later» shows the same notification again after 60 or 180 minutes or tomorrow at 9:00 by the phone clock — the phone does it itself, even offline, and the platform does not send it again. A press passed on twice (the delegate and a wrapper) is reported once. With your own delegate pass the press on:

```swift
OneTrace.handleNotificationOpen(response.notification.request.content.userInfo, actionIdentifier: response.actionIdentifier)
```

If two notifications with different buttons are on the screen, both show the buttons of the newer one: iOS declares buttons by category.

### Carousel and countdown

Add a Notification Content Extension target with the `OneTraceNotificationContent` product:

```swift
import OneTraceNotificationContent

class NotificationViewController: OneTraceNotificationContentViewController {
    override var appGroup: String? { "group.com.example.shop" }   // optional, see below
}
```

In its Info.plist, under `NSExtension` → `NSExtensionAttributes`:

```xml
<key>UNNotificationExtensionCategory</key>
<array>
    <string>cdp_carousel</string>
    <string>cdp_timer</string>
</array>
<key>UNNotificationExtensionUserInteractionEnabled</key>
<true/>
<key>UNNotificationExtensionInitialContentSizeRatio</key>
<real>0.8</real>
```

and replace `NSExtensionMainStoryboard` with `NSExtensionPrincipalClass` = `$(PRODUCT_MODULE_NAME).NotificationViewController`. An expanded notification then shows the carousel (swipe through the cards) and the countdown. A tap on a card opens the app with the card link when the app and the extension share an App Group: add the same group to both targets and pass it as `OneTraceConfig(…, appGroup: "group.com.example.shop")`; without it the message link opens. The carousel pictures are downloaded by `OneTraceNotificationService` (up to 10 seconds and 1 MB each). Keep the timer end in the text with the content extension too, or override `appendsTimerEnd` with false in your `NotificationService`.

### Silent checks

Once a week the platform checks installations that have not opened the app for a while with a silent push (`content-available`), to notice removed apps. It shows nothing and reports nothing; if you implement `application(_:didReceiveRemoteNotification:fetchCompletionHandler:)`:

```swift
if OneTrace.isSilentCheck(userInfo) { return completionHandler(.noData) }
```

## Live Activities

Order and delivery statuses and countdowns on the lock screen and in the Dynamic Island (iOS 16.1+), started, updated and ended by OneTrace journeys and your server through APNs (the **Mobile push** integration needs the APNs key). Add `NSSupportsLiveActivities` = YES to the app Info.plist and a widget extension with the activity of `OneTraceActivityAttributes`:

```swift
import ActivityKit
import OneTrace
import SwiftUI
import WidgetKit

struct OrderActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: OneTraceActivityAttributes.self) { context in
            VStack(alignment: .leading, spacing: 6) {
                Text(context.state.title).font(.headline)
                if let status = context.state.status { Text(status).font(.subheadline) }
                if let progress = context.state.progress { ProgressView(value: progress) }
                if let end = context.state.endsAt {
                    // Counts down by itself; after `stale-date` the system marks the activity as outdated.
                    Text(timerInterval: Date()...max(Date(), end), countsDown: true).monospacedDigit()
                }
                if context.isStale { Text("Updating…").font(.caption).foregroundStyle(.secondary) }
            }
            .padding()
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.bottom) { Text(context.state.status ?? context.state.title) }
            } compactLeading: {
                Text(context.state.title).lineLimit(1)
            } compactTrailing: {
                if let end = context.state.endsAt { Text(timerInterval: Date()...max(Date(), end), countsDown: true).monospacedDigit() }
            } minimal: {
                Image(systemName: "shippingbox")
            }
        }
    }
}
```

`context.state` has `title`, `status`, `step` and `steps` (up to 6 step names), `progress` (0…1), `endsAt` and `data` (your own strings); `context.attributes` — the `type` and `key` the platform updates the activity by, for example `order` and the order number.

Start an activity in the app and hand it to OneTrace — its push token, token changes and its end go to the platform:

```swift
let activity = try Activity.request(
    attributes: OneTraceActivityAttributes(type: "order", key: "1001"),
    content: .init(state: .init(title: "Order 1001", status: "Accepted", step: 0, steps: ["Accepted", "Packed", "On the way", "Delivered"]), staleDate: nil),
    pushType: .token
)
OneTrace.liveActivities.track(activity)
```

At every launch call `OneTrace.liveActivities.trackAll()` (iOS 16.1+): tokens of running activities change. On iOS 17.2+ the platform can start the activity itself (push-to-start) — then call `OneTrace.liveActivities.enablePushToStart(types: ["order"])` with the activity types of your templates instead; it tracks the activities it starts too. The installation reports `live_activities` while the user allows Live Activities of the app.

## Geofences

Zones of the project (Apps → Geofences in OneTrace) as events: `geofence_entered`, `geofence_dwelled` (in the zone longer than its time) and `geofence_exited` with `dwell_seconds`, with the zone id, external id and name — never the coordinates of the device. Use them in journeys and segments like any event.

Add the `OneTraceLocation` product to the app and the location strings to Info.plist: `NSLocationWhenInUseUsageDescription` and `NSLocationAlwaysAndWhenInUseUsageDescription`. The SDK never asks for the permission itself — ask when it makes sense to the user, with your own screen or with the helper («While Using the App», then «Always»):

```swift
import OneTraceLocation

OneTraceLocation.requestLocationPermission { permission in
    // .none, .foreground or .always
}
```

and turn the zones on — also in `application(_:didFinishLaunchingWithOptions:)`, after `OneTrace.setup`, because iOS starts the app in the background for a zone event:

```swift
let status = OneTraceLocation.enableGeofences()   // .enabled, .needsAlwaysPermission, .unavailable, .notSetUp
```

Without «Always» nothing is watched; once the user allows it, the zones start without a restart. The installation reports the permission (`none`, `foreground`, `always`) for segments.

- iOS watches 20 regions per app: the SDK keeps the nearest 18 zones (`OneTraceLocation.maxMonitored`, up to 19) and a refresh region around the device; leaving it, it picks the nearest zones again.
- The zone list is loaded at start and every 12 hours; removed and switched off zones stop being watched with the next list.
- `geofence_dwelled` comes at the first wake-up of the app inside the zone after its time, so it may come later than on Android.
- Coming back into a zone within 30 minutes of leaving it is not reported (GPS jitter at the border), nor is the exit of that visit. An exit without a recorded entry (the phone was off) comes without `dwell_seconds`; an entry older than 24 hours is dropped.
- Zone events are ordinary events: they wait in the queue offline and count towards the events of your plan.

## Remote Config

App parameters (Apps → App settings in OneTrace): a key, a type, a default and rules by segment, platform and app version. Read them anywhere:

```swift
let banner = OneTrace.remoteConfig.getString("home_banner", "summer")
if OneTrace.remoteConfig.getBoolean("new_checkout", false) { … }
let limit = OneTrace.remoteConfig.getLong("cart_limit", 20)
let discount = OneTrace.remoteConfig.getDouble("discount", 0)
let layout = OneTrace.remoteConfig.getJson("layout") as? [String: Any]

let observation = OneTrace.remoteConfig.addListener { changedKeys in … }   // on the main thread
OneTrace.remoteConfig.fetch { changed in … }
```

The SDK asks for the values when the app starts and opens, at most once an hour (`OneTraceConfig.remoteConfigMinFetchInterval`), and at once after `identify` and `reset`; unchanged values cost a `304`. Until the first answer and offline the getters return the saved values, without them — the defaults you pass.

## Message feed

Personal cards — an offer, news, a reminder, a promo code — that stay in the app (and on your website) until they expire or the user removes them, with an unread count for a badge. Unlike in-app messages, a card is not shown once and gone: it waits in the feed. Cards are sent by journeys and campaigns through the **Message feed** channel, a feature of the OneTrace plan; without it the feed is empty.

**Ready-made screen.** One call shows the feed modally with a Close button:

```swift
OneTrace.presentFeed()                       // over the top screen
OneTrace.presentFeed(from: self)             // or over a view controller of yours
```

Or push it, or put it into a tab:

```swift
navigationController?.pushViewController(OneTraceFeedViewController(), animated: true)
```

In SwiftUI:

```swift
.sheet(isPresented: $showFeed) {
    NavigationView {
        OneTraceFeedView().navigationBarTitle(Text(OneTraceFeedView.title()), displayMode: .inline)
    }
}
```

The screen shows the cards in their layout (image on the left, image on top, or image only), pinned ones first, a remove button on each, pull to refresh and an empty state. A card at least half visible on the open screen is reported as shown: it is read, and the message is delivered and opened in the reports. A tap on the button — or on a card without a button — reports the click and opens the link like push links (`https://…` or your deep link; with `openPushLinks: false` the SDK only reports it). The labels («Updates», the empty state, «Remove», «Pinned») follow the device language: English, Russian, German, Uzbek, Turkish, Spanish, French, Italian, Portuguese or Chinese, English otherwise; pass `language:` to choose. Colors follow the light or dark appearance, unread cards and buttons take the app tint.

**Unread badge.**

```swift
let badge = OneTrace.observeFeedUnread { count in      // on the main thread, now and on every change
    feedButton.badgeValue = count > 0 ? "\(count)" : nil
}
// badge.cancel() when it is no longer needed
```

Once the app uses the feed, the SDK refreshes it when the app opens and after `reset()`; `OneTrace.feedUnreadCount` is the last count.

**Your own UI.** Load the cards and report what the user sees and does:

```swift
OneTrace.fetchFeed { cards in            // main thread; or `let cards = await OneTrace.fetchFeed()`
    self.cards = cards                   // OneTraceFeedCard: layout, title, body, imageURL, buttonText, buttonURL, pinned, read…
}
let updates = OneTrace.observeFeed { cards in self.cards = cards }   // after shows, clicks and removals

OneTrace.feedCardShown(card)             // at least half of the card is on screen; reported once
OneTrace.feedCardClicked(card)           // the button, or the card if `card.opensOnTap`: reports and opens buttonURL
OneTrace.feedCardDismissed(card)         // removed: never returned again
```

A show that has not reached OneTrace yet (no network) still counts as read for the rest of the session, and a removed card does not come back on a refresh.

## How it works

- Every installation has a random id; while push can be sent, it is the `mobile_push` identity of the profile, and the profile is reachable by the **Mobile push** channel in journeys and campaigns.
- `identify` and `reset` re-register the installation: after a sign-out push goes to the next user, the profiles are not merged.
- Events are sent when 20 are queued, every 30 seconds and when the app goes to the background; up to 1,000 are kept on disk.
- The message feed and Remote Config values are loaded by the anonymous id of the installation (never by the user id, which could be guessed), with the write key.
- The installation reports what it can show (`rich`, `live_activities`, `silent`) and, with `OneTraceLocation`, the location permission; the platform picks the kind of push by them.

## Tests

`swift test` runs the core tests (macOS or Linux: the push keys, the timer text, «Remind me later», Remote Config, Live Activity reports and state, the zone selection and visits); CI also builds every target for the iOS simulator, including ActivityKit, UserNotifications and CoreLocation code. Against a real project:

```bash
ONETRACE_URL=https://crm.example.com ONETRACE_KEY=cdp_wk_… swift test --filter LiveTests
```

## License

MIT
