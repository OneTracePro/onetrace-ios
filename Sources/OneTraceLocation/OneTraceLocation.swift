import Foundation
@_spi(OneTraceLocation) import OneTrace
#if canImport(CoreLocation) && os(iOS)
import CoreLocation
#endif

/// The result of `OneTraceLocation.enableGeofences()`.
public enum GeofenceStatus: String {
    /// The zones are watched.
    case enabled
    /// The app has no «Always» location permission: nothing is watched yet. Once the user allows it, the zones start
    /// without a restart.
    case needsAlwaysPermission
    /// The device cannot watch regions.
    case unavailable
    /// `OneTrace.setup` was not called.
    case notSetUp
}

/// The location permission of the app, as the installation reports it.
public enum LocationPermission: String {
    case none
    /// «While Using the App».
    case foreground
    /// «Always»: needed for geofences.
    case always
}

/// Geofences of OneTrace: `geofence_entered`, `geofence_dwelled` and `geofence_exited` events for the zones of the
/// project (Apps → Geofences), for journeys and segments. Only the zone ids go to OneTrace, never the coordinates.
///
/// The SDK never asks for the location permission by itself: ask at the right moment with
/// `requestLocationPermission()` (or your own prompt), then `enableGeofences()`. Call `enableGeofences()` in
/// `application(_:didFinishLaunchingWithOptions:)` too: iOS starts the app in the background for a zone event.
public enum OneTraceLocation {
    private static let lock = NSLock()
    private static var configuredMax = 18

    /// How many zones iOS watches, the nearest ones: from 1 to 19 (iOS gives an app 20 regions, one is the refresh
    /// region). 18 by default, leaving one region for the app.
    public static var maxMonitored: Int {
        get {
            lock.lock()
            defer { lock.unlock() }
            return configuredMax
        }
        set {
            lock.lock()
            configuredMax = min(19, max(1, newValue))
            lock.unlock()
        }
    }

    /// Starts watching the zones. Without the «Always» permission nothing is watched and the reason is returned; the
    /// zones start by themselves once the permission comes.
    @discardableResult
    public static func enableGeofences() -> GeofenceStatus {
        guard OneTrace.isSetUp else { return .notSetUp }
        #if canImport(CoreLocation) && os(iOS)
        return onMain { GeofenceMonitor.shared.enable() }
        #else
        return .unavailable
        #endif
    }

    /// For an app on Flutter or React Native: call it in `application(_:didFinishLaunchingWithOptions:)`. The wrapper's
    /// `enableGeofences`, `disableGeofences` and `requestLocationPermission` then reach this product (the wrappers do
    /// not link it, so an app without geofences needs no location purpose strings), and the location manager is ready
    /// for a zone event when iOS starts the app in the background.
    public static func register() {
        OneTrace.geofences = OneTraceGeofenceHooks(
            enable: { OneTraceLocation.enableGeofences().rawValue },
            disable: { OneTraceLocation.disableGeofences() },
            requestPermission: { completion in OneTraceLocation.requestLocationPermission { completion($0.rawValue) } }
        )
        #if canImport(CoreLocation) && os(iOS)
        onMain { _ = GeofenceMonitor.shared }
        #endif
    }

    /// Stops watching the zones and forgets the visits.
    public static func disableGeofences() {
        #if canImport(CoreLocation) && os(iOS)
        onMain { GeofenceMonitor.shared.disable() }
        #endif
    }

    /// Asks the user for the location permission in two steps: «While Using the App», then «Always». `completion` runs
    /// on the main thread with the permission once the user answers. The SDK never calls it by itself.
    public static func requestLocationPermission(_ completion: ((LocationPermission) -> Void)? = nil) {
        #if canImport(CoreLocation) && os(iOS)
        onMain { GeofenceMonitor.shared.requestPermission(completion) }
        #else
        if let completion = completion { DispatchQueue.main.async { completion(.none) } }
        #endif
    }

    /// The current location permission of the app.
    public static var permission: LocationPermission {
        #if canImport(CoreLocation) && os(iOS)
        return onMain { GeofenceMonitor.shared.permission }
        #else
        return .none
        #endif
    }

    private static func onMain<T>(_ work: () -> T) -> T {
        Thread.isMainThread ? work() : DispatchQueue.main.sync(execute: work)
    }
}

/// The saved zone list, its version and the time it was loaded; whether the app wants geofences.
final class GeofenceStore {
    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    var list: GeofenceList? {
        get { defaults.data(forKey: "geofence_list").flatMap { try? JSONDecoder().decode(GeofenceList.self, from: $0) } }
        set { defaults.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: "geofence_list") }
    }

    var etag: String? {
        get { defaults.string(forKey: "geofence_etag") }
        set { defaults.set(newValue, forKey: "geofence_etag") }
    }

    var loadedAt: Date? {
        get { (defaults.object(forKey: "geofence_loaded_at") as? Double).map { Date(timeIntervalSince1970: $0) } }
        set { defaults.set(newValue?.timeIntervalSince1970, forKey: "geofence_loaded_at") }
    }

    var wanted: Bool {
        get { defaults.bool(forKey: "geofences_wanted") }
        set { defaults.set(newValue, forKey: "geofences_wanted") }
    }

    /// The list is loaded at start and then every `refreshHours` (12).
    func due(now: Date) -> Bool {
        guard let loadedAt = loadedAt else { return true }
        let hours = Double(list?.refreshHours ?? 12)
        let elapsed = now.timeIntervalSince(loadedAt)
        return elapsed < 0 || elapsed >= hours * 3600
    }

    /// Saves an answer of `GET /geofences`; true when the saved list is current (200, 304). A refusal the next request
    /// would get too (402 without the plan's feature, other 4xx but 429) waits for the refresh interval as well,
    /// instead of a request at every launch; the network and 429, 5xx are asked again at the next start.
    @discardableResult
    func record(status: Int, body: String, etag: String?, now: Date) -> Bool {
        if status == 304, list != nil {
            loadedAt = now
            return true
        }
        if (200..<300).contains(status), let fresh = GeofenceList(json: body) {
            list = fresh
            self.etag = etag ?? fresh.version
            loadedAt = now
            return true
        }
        if (400..<500).contains(status), status != 429 {
            loadedAt = now
        }
        return false
    }
}

#if canImport(CoreLocation) && os(iOS)
/// CoreLocation regions of the zones, on the main thread.
final class GeofenceMonitor: NSObject, CLLocationManagerDelegate {
    static let shared = GeofenceMonitor()

    private let manager = CLLocationManager()
    private let store: GeofenceStore
    private let visits: GeofenceVisits
    private var loading = false
    private var askingAlways = false
    private var permissionCallbacks: [(LocationPermission) -> Void] = []

    override init() {
        let defaults = UserDefaults(suiteName: "pro.onetrace.location") ?? .standard
        store = GeofenceStore(defaults: defaults)
        visits = GeofenceVisits(defaults: defaults)
        super.init()
        manager.delegate = self
    }

    var status: CLAuthorizationStatus {
        if #available(iOS 14.0, *) { return manager.authorizationStatus }
        return CLLocationManager.authorizationStatus()
    }

    var permission: LocationPermission {
        switch status {
        case .authorizedAlways: return .always
        case .authorizedWhenInUse: return .foreground
        default: return .none
        }
    }

    func enable() -> GeofenceStatus {
        report()
        store.wanted = true
        guard CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) else { return .unavailable }
        guard status == .authorizedAlways else { return .needsAlwaysPermission }
        start()
        return .enabled
    }

    func disable() {
        store.wanted = false
        ownRegions().forEach { manager.stopMonitoring(for: $0) }
        visits.reset()
    }

    func requestPermission(_ completion: ((LocationPermission) -> Void)?) {
        switch status {
        case .notDetermined:
            if let completion = completion { permissionCallbacks.append(completion) }
            askingAlways = true
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse:
            if let completion = completion { permissionCallbacks.append(completion) }
            askingAlways = false
            manager.requestAlwaysAuthorization()
        default:
            completion?(permission)
        }
    }

    // MARK: - Zones

    /// Loads the list when it is due, picks the nearest zones and checks the stays.
    private func start() {
        refreshList()
        apply(location: manager.location)
        manager.requestLocation()
        ownRegions().forEach { manager.requestState(for: $0) }
        track(visits.wake(at: Date()))
    }

    private func refreshList() {
        guard !loading, store.due(now: Date()) else { return }
        loading = true
        let etag = store.list == nil ? nil : store.etag
        let started = OneTrace.loadGeofences(etag: etag) { [weak self] status, body, newEtag in
            DispatchQueue.main.async { self?.loaded(status: status, body: body, etag: newEtag) }
        }
        if !started { loading = false }
    }

    private func loaded(status: Int, body: String, etag: String?) {
        loading = false
        guard store.record(status: status, body: body, etag: etag, now: Date()) else { return }
        if store.wanted, self.status == .authorizedAlways {
            apply(location: manager.location)
        }
    }

    /// Hands iOS the nearest zones and the refresh region; removed or switched off zones stop being watched.
    private func apply(location: CLLocation?) {
        guard store.wanted, status == .authorizedAlways, let list = store.list else { return }

        let point = location.map { GeoPoint(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude) }
        let selector = GeofenceSelector(maxZones: OneTraceLocation.maxMonitored, maxRadius: manager.maximumRegionMonitoringDistance)
        let selection = selector.select(list.geofences, around: point)

        var wanted: [String: CLCircularRegion] = [:]
        for zone in selection.zones {
            let center = CLLocationCoordinate2D(latitude: zone.latitude, longitude: zone.longitude)
            let region = CLCircularRegion(center: center, radius: min(zone.radius, manager.maximumRegionMonitoringDistance), identifier: zone.regionId)
            region.notifyOnEntry = true
            region.notifyOnExit = true
            wanted[region.identifier] = region
        }
        if let radius = selection.refreshRadius, let center = selection.center {
            let region = CLCircularRegion(
                center: CLLocationCoordinate2D(latitude: center.latitude, longitude: center.longitude),
                radius: radius, identifier: GeofenceList.refreshRegionId
            )
            region.notifyOnEntry = false
            region.notifyOnExit = true
            wanted[region.identifier] = region
        }

        for region in ownRegions() {
            guard let fresh = wanted[region.identifier], let circle = region as? CLCircularRegion,
                  circle.center.latitude == fresh.center.latitude, circle.center.longitude == fresh.center.longitude,
                  circle.radius == fresh.radius else {
                manager.stopMonitoring(for: region)
                continue
            }
            wanted[region.identifier] = nil
        }
        wanted.values.forEach { manager.startMonitoring(for: $0) }
    }

    private func ownRegions() -> [CLRegion] {
        Array(manager.monitoredRegions).filter {
            $0.identifier.hasPrefix(GeofenceList.regionPrefix) || $0.identifier == GeofenceList.refreshRegionId
        }
    }

    private func zone(_ region: CLRegion) -> Geofence? {
        store.list?.zone(regionId: region.identifier)
    }

    private func track(_ events: [GeofenceEvent]) {
        guard !events.isEmpty else { return }
        events.forEach { OneTrace.track($0.name, $0.properties) }
        OneTrace.flush()
    }

    private func report() {
        OneTrace.setLocationPermission(permission.rawValue)
    }

    // MARK: - CLLocationManagerDelegate

    func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        guard let zone = zone(region) else { return }
        track(visits.enter(zone, at: Date()))
        track(visits.wake(at: Date()))
    }

    func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        if region.identifier == GeofenceList.refreshRegionId {
            manager.requestLocation()
            return
        }
        guard let zone = zone(region) else { return }
        track(visits.exit(zone, at: Date()))
    }

    func locationManager(_ manager: CLLocationManager, didDetermineState state: CLRegionState, for region: CLRegion) {
        guard let zone = zone(region) else { return }
        switch state {
        case .inside:
            track(visits.enter(zone, at: Date()))
            track(visits.wake(at: Date()))
        case .outside:
            track(visits.exit(zone, at: Date(), confirmed: false))
        default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        apply(location: locations.last)
        refreshList()
        track(visits.wake(at: Date()))
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}

    func locationManager(_ manager: CLLocationManager, monitoringDidFailFor region: CLRegion?, withError error: Error) {}

    @available(iOS 14.0, *)
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationChanged()
    }

    func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        if #available(iOS 14.0, *) { return }
        authorizationChanged()
    }

    /// The second step of the request, the permission in the installation, the zones on or off.
    private func authorizationChanged() {
        report()

        if askingAlways, status == .authorizedWhenInUse {
            askingAlways = false
            manager.requestAlwaysAuthorization()
            return
        }
        if status != .notDetermined {
            let callbacks = permissionCallbacks
            permissionCallbacks = []
            callbacks.forEach { $0(permission) }
        }

        if status == .authorizedAlways {
            if store.wanted { start() }
        } else {
            ownRegions().forEach { manager.stopMonitoring(for: $0) }
        }
    }
}
#endif
