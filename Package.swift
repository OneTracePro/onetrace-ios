// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "OneTrace",
    platforms: [.iOS(.v13), .macOS(.v10_15)],
    products: [
        .library(name: "OneTrace", targets: ["OneTrace"]),
        // For a Notification Service Extension: images, carousel pictures, buttons and the timer end in push notifications.
        .library(name: "OneTraceNotificationService", targets: ["OneTraceNotificationService"]),
        // For a Notification Content Extension: the carousel and the countdown of an expanded notification.
        .library(name: "OneTraceNotificationContent", targets: ["OneTraceNotificationContent"]),
        // Geofences: entering, leaving and staying in the project's zones (CoreLocation regions).
        .library(name: "OneTraceLocation", targets: ["OneTraceLocation"]),
    ],
    targets: [
        // The `cdp_*` keys of OneTrace push messages, shared by the SDK and both extensions; Foundation only.
        .target(name: "OneTracePush"),
        .target(name: "OneTrace", dependencies: ["OneTracePush"]),
        .target(name: "OneTraceNotificationService", dependencies: ["OneTracePush"]),
        .target(name: "OneTraceNotificationContent", dependencies: ["OneTracePush"]),
        .target(name: "OneTraceLocation", dependencies: ["OneTrace"]),
        .testTarget(name: "OneTraceTests", dependencies: ["OneTrace", "OneTracePush", "OneTraceLocation"]),
    ]
)
