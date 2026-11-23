import Foundation

/// The calls of the `OneTraceLocation` product the Flutter and React Native wrappers make through the core
/// (`OneTrace.geofences`): the wrappers link only the core, the app links `OneTraceLocation` when it needs geofences.
@_spi(OneTraceLocation)
public struct OneTraceGeofenceHooks {
    /// `OneTraceLocation.enableGeofences()`: the raw value of its `GeofenceStatus`.
    public let enable: () -> String
    /// `OneTraceLocation.disableGeofences()`.
    public let disable: () -> Void
    /// `OneTraceLocation.requestLocationPermission()`: the raw value of the `LocationPermission` once the user answers.
    public let requestPermission: (_ completion: @escaping (String) -> Void) -> Void

    public init(enable: @escaping () -> String, disable: @escaping () -> Void, requestPermission: @escaping (_ completion: @escaping (String) -> Void) -> Void) {
        self.enable = enable
        self.disable = disable
        self.requestPermission = requestPermission
    }
}
