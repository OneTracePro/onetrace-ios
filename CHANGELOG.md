# Changelog

## Unreleased

- Rich notifications: `OneTraceNotificationService` registers the buttons of the message (category `cdp_buttons_{hash8}`, or the fixed `cdp_carousel` and `cdp_timer`), downloads the carousel pictures (up to 10 seconds and 1 MB each) and adds the end of the timer to the text by the phone clock and language («until 18:00»; `appendsTimerEnd`).
- A new product `OneTraceNotificationContent`: `OneTraceNotificationContentViewController` for a Notification Content Extension — the carousel (swipe, a tap opens the card link through `OneTraceConfig.appGroup`) and the countdown of an expanded notification.
- Buttons: `OneTraceNotificationDelegate` and `handleNotificationOpen(_:actionIdentifier:)` report the open with the button id (`action`) and its link once, «Close» reports nothing, «Remind me later» schedules a local copy after 60 or 180 minutes or tomorrow at 9:00 by the phone clock. The silent check (`content-available`) shows and reports nothing; `OneTrace.isSilentCheck(_:)`.
- Live Activities (iOS 16.1+): `OneTraceActivityAttributes` with the standard `ContentState` (`title`, `status`, `step`, `steps`, `progress`, `endsAt`, `data`), `OneTrace.liveActivities.track(_:)` and `trackAll()` report push tokens, token changes, ends and dismissals; `enablePushToStart(types:)` (iOS 17.2+) registers the push-to-start token. A widget example in the README.
- Remote Config: `OneTrace.remoteConfig.getString/getBoolean/getLong/getDouble/getJson(key, default)`, `fetch`, `addListener`/`removeListener`; at start and when the app opens at most once per `remoteConfigMinFetchInterval` (an hour), at once after `identify` and `reset`, with `ETag`/`304`; the saved values offline, the app defaults without them.
- A new product `OneTraceLocation`: geofences — `enableGeofences()` (nothing without the «Always» permission; it starts by itself once granted), `disableGeofences()`, `requestLocationPermission()` (never called by the SDK), `maxMonitored` (18 nearest zones and a refresh region), the zone list every 12 hours with `ETag`; `geofence_entered`, `geofence_dwelled`, `geofence_exited` with `dwell_seconds`, only zone ids; a re-entry within 30 minutes of an exit is not reported.
- The installation reports `push.capabilities` (`rich`, `live_activities`, `silent`) and, with `OneTraceLocation`, `location.permission`.

## 1.2.0 — 2026-11-09

- Message feed: personal cards that stay in the app until they expire or the user removes them. `fetchFeed` (callback or `async`), `feedCards`, the unread count with `observeFeedUnread` for a badge, `observeFeed` for your own UI, and `feedCardShown`, `feedCardClicked` (opens the link like push links) and `feedCardDismissed` reports. A show not confirmed by the server yet stays read for the session; a removed card does not come back on a refresh. Refreshed when the app opens and after `reset()` once the app uses the feed.
- A ready-made feed screen: `OneTraceFeedViewController` for UIKit, `OneTraceFeedView` for SwiftUI and `OneTrace.presentFeed()` in one call — classic, captioned and banner cards, pinned first, remove button, pull to refresh, empty state, shown reports for cards at least half visible, labels in 10 languages, light and dark appearance.
## 1.1.0 — 2026-11-02

- Signed user ids (`userHash`): `identify(_:traits:userHash:)` and `alias(_:userHash:)` keep the signature from your server with the user id and send it with every event and the installation registration; `reset()` clears it. Required when the project turns on the user id signature.

## 1.0.0 — 2026-10-31

- Events, screens, identify, alias and reset with the Segment Spec format of the OneTrace.pro API.
- A persistent queue: events survive restarts and offline periods, are sent in batches and retried on network errors, `429` and `5xx`.
- App lifecycle events: `app_installed`, `app_updated`, `app_opened`, `app_backgrounded`; a flush when the app goes to the background.
- Installation registration for mobile push: the APNs (or FCM) token, the notification permission, the app and device details; a sign-out moves the installation to the next user.
- `OneTraceNotificationDelegate`: foreground presentation and delivery receipts of OneTrace notifications, opens and links of tapped ones.
- In-app messages: fetched when the app opens and after events are sent, shown over the key window as a modal, a banner or a full screen; shown, button taps and closes are reported.
- `OneTraceNotificationService`: images in notifications through a Notification Service Extension.
- Numbers from Objective-C and the wrappers (`NSNumber`) stay numbers: `1` is no longer sent as `true`.
- A notification tap is reported once, even when both `OneTraceNotificationDelegate` and a wrapper (Flutter, React Native) pass it on.
