# Changelog

## 1.0.0 — 2026-10-30

- Events, screens, identify, alias and reset with the Segment Spec format of the OneTrace.pro API.
- A persistent queue: events survive restarts and offline periods, are sent in batches and retried on network errors, `429` and `5xx`.
- App lifecycle events: `app_installed`, `app_updated`, `app_opened`, `app_backgrounded`; a flush when the app goes to the background.
- Installation registration for mobile push: the APNs (or FCM) token, the notification permission, the app and device details; a sign-out moves the installation to the next user.
- `OneTraceNotificationDelegate`: foreground presentation and delivery receipts of OneTrace notifications, opens and links of tapped ones.
- In-app messages: fetched when the app opens and after events are sent, shown over the key window as a modal, a banner or a full screen; shown, button taps and closes are reported.
- `OneTraceNotificationService`: images in notifications through a Notification Service Extension.
- Numbers from Objective-C and the wrappers (`NSNumber`) stay numbers: `1` is no longer sent as `true`.
- A notification tap is reported once, even when both `OneTraceNotificationDelegate` and a wrapper (Flutter, React Native) pass it on.
