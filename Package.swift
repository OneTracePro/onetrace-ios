// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "OneTrace",
    platforms: [.iOS(.v13), .macOS(.v10_15)],
    products: [
        .library(name: "OneTrace", targets: ["OneTrace"]),
        // For a Notification Service Extension: images in push notifications.
        .library(name: "OneTraceNotificationService", targets: ["OneTraceNotificationService"]),
    ],
    targets: [
        .target(name: "OneTrace"),
        .target(name: "OneTraceNotificationService"),
        .testTarget(name: "OneTraceTests", dependencies: ["OneTrace"]),
    ]
)
