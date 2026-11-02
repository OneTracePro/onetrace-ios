import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// The app and device in Segment Spec terms: `context.app`, `context.device`, `context.os`, locale, time zone, screen
/// and the library that sent the event.
final class DeviceContext {
    static let sdkVersion = "1.1.0"

    let installationId: String
    private let bundle: Bundle

    /// Set by the Flutter and React Native wrappers: they report themselves as the library.
    var wrapper: (name: String, version: String)?

    init(installationId: String, bundle: Bundle = .main) {
        self.installationId = installationId
        self.bundle = bundle
    }

    var bundleId: String { bundle.bundleIdentifier ?? "unknown" }

    var appVersion: String { bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "" }

    var appBuild: String { bundle.infoDictionary?["CFBundleVersion"] as? String ?? "" }

    var appName: String {
        bundle.infoDictionary?["CFBundleDisplayName"] as? String ?? bundle.infoDictionary?["CFBundleName"] as? String ?? bundleId
    }

    var locale: String { Locale.preferredLanguages.first ?? Locale.current.identifier }

    var timezone: String { TimeZone.current.identifier }

    var osVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return v.patchVersion > 0 ? "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)" : "\(v.majorVersion).\(v.minorVersion)"
    }

    /// Hardware model, for example `iPhone16,2`.
    var model: String {
        #if targetEnvironment(simulator)
        return ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? "Simulator"
        #else
        var info = utsname()
        uname(&info)
        return withUnsafePointer(to: &info.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
        #endif
    }

    /// «ios 1.0.0» or «flutter 1.0.0» for the device registration.
    var sdk: (name: String, version: String) { wrapper ?? ("ios", Self.sdkVersion) }

    var library: [String: Any] {
        ["name": wrapper.map { "onetrace-\($0.name)" } ?? "onetrace-ios", "version": wrapper?.version ?? Self.sdkVersion]
    }

    func build() -> [String: Any] {
        var context: [String: Any] = [
            "app": ["name": appName, "version": appVersion, "build": appBuild, "namespace": bundleId],
            "device": ["id": installationId, "manufacturer": "Apple", "model": model, "type": "ios"],
            "os": ["name": "ios", "version": osVersion],
            "locale": locale,
            "timezone": timezone,
            "library": library,
        ]

        #if canImport(UIKit) && !os(watchOS)
        if Thread.isMainThread {
            let bounds = UIScreen.main.bounds
            context["screen"] = ["width": Int(bounds.width), "height": Int(bounds.height), "density": Double(UIScreen.main.scale)]
        }
        #endif

        return context
    }
}
