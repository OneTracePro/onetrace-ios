# Changelog

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
