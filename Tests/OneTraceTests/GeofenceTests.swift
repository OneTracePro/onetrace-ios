import Foundation
import XCTest
import OneTrace
@testable import OneTraceLocation
#if canImport(CoreLocation) && os(iOS)
import CoreLocation
#endif

final class GeofenceTests: XCTestCase {
    /// Moscow, Red Square.
    private let here = GeoPoint(latitude: 55.7539, longitude: 37.6208)

    /// One degree of latitude is 111.2 km: zone `n` lies `n` km north of `here`, radius 100 m.
    private func zones(_ count: Int) -> [Geofence] {
        (1...count).reversed().map { n in
            Geofence(id: n, externalId: "store_\(n)", name: "Store \(n)", latitude: here.latitude + Double(n) / 111.195, longitude: here.longitude, radius: 100, dwellSeconds: 300)
        }
    }

    private func visits() -> GeofenceVisits {
        GeofenceVisits(defaults: UserDefaults(suiteName: "onetrace-tests-\(UUID().uuidString)")!)
    }

    private let store15 = Geofence(id: 15, externalId: "store_15", name: "Store on Tverskaya", latitude: 55.7650, longitude: 37.6050, radius: 150, dwellSeconds: 300)

    func testWatchesTheEighteenNearestZonesAndARefreshRegionUpToTheNextOne() {
        let selection = GeofenceSelector().select(zones(25), around: here)

        XCTAssertEqual(selection.zones.map(\.id), Array(1...18))
        // The 19th zone is 19 km away, its edge 100 m closer.
        XCTAssertEqual(selection.refreshRadius ?? 0, 18_900, accuracy: 30)
        XCTAssertEqual(selection.center, here)

        let fewer = GeofenceSelector(maxZones: 5).select(zones(25), around: here)
        XCTAssertEqual(fewer.zones.map(\.id), [1, 2, 3, 4, 5])
        XCTAssertEqual(fewer.refreshRadius ?? 0, 5_900, accuracy: 30)
    }

    func testABigZoneIsNearOnceItsBorderIsAndAllZonesNeedNoRefreshRegion() {
        var list = zones(3)
        list.append(Geofence(id: 99, externalId: nil, name: "Park", latitude: here.latitude + 10 / 111.195, longitude: here.longitude, radius: 9_950, dwellSeconds: 600))

        let selection = GeofenceSelector().select(list, around: here)
        XCTAssertEqual(selection.zones.map(\.id), [99, 1, 2, 3])
        XCTAssertNil(selection.refreshRadius)

        // Without a location: the first zones of the list until it comes.
        XCTAssertEqual(GeofenceSelector(maxZones: 2).select(list, around: nil).zones.map(\.id), [3, 2])
        XCTAssertEqual(GeoPoint(latitude: 0, longitude: 0).distance(to: GeoPoint(latitude: 1, longitude: 0)), 111_195, accuracy: 10)
    }

    func testTheTimeInTheZoneWithoutCoordinatesInTheEvents() {
        let visits = visits()
        let start = Date(timeIntervalSince1970: 1_800_000_000)

        let entered = visits.enter(store15, at: start)
        XCTAssertEqual(entered.map(\.name), ["geofence_entered"])
        XCTAssertNil(entered[0].dwellSeconds)
        XCTAssertTrue(visits.enter(store15, at: start.addingTimeInterval(5)).isEmpty, "iOS reports the state inside again")

        XCTAssertTrue(visits.wake(at: start.addingTimeInterval(299)).isEmpty)
        let dwelled = visits.wake(at: start.addingTimeInterval(420))
        XCTAssertEqual(dwelled.map(\.name), ["geofence_dwelled"])
        XCTAssertEqual(dwelled.first?.dwellSeconds, 420)
        XCTAssertTrue(visits.wake(at: start.addingTimeInterval(600)).isEmpty, "once per visit")

        let exited = visits.exit(store15, at: start.addingTimeInterval(1_000))
        XCTAssertEqual(exited.map(\.name), ["geofence_exited"])
        XCTAssertEqual(exited.first?.dwellSeconds, 1_000)
        XCTAssertTrue(visits.exit(store15, at: start.addingTimeInterval(1_010), confirmed: false).isEmpty, "the state outside after the exit")

        let properties = exited[0].properties
        XCTAssertEqual(Set(properties.keys), ["geofence_id", "geofence_external_id", "geofence_name", "dwell_seconds"])
        XCTAssertEqual(properties["geofence_id"] as? Int, 15)
        XCTAssertEqual(properties["geofence_external_id"] as? String, "store_15")
        XCTAssertEqual(properties["geofence_name"] as? String, "Store on Tverskaya")
        XCTAssertEqual(Set(entered[0].properties.keys), ["geofence_id", "geofence_external_id", "geofence_name"])
    }

    func testALostEntryGivesNoTimeAndAnEntryOlderThanADayIsDropped() {
        let visits = visits()
        let start = Date(timeIntervalSince1970: 1_800_000_000)

        let lost = visits.exit(store15, at: start)
        XCTAssertEqual(lost.map(\.name), ["geofence_exited"])
        XCTAssertNil(lost[0].dwellSeconds)
        XCTAssertNil(lost[0].properties["dwell_seconds"] ?? nil)
        XCTAssertTrue(visits.exit(store15, at: start.addingTimeInterval(30)).isEmpty, "the same exit reported twice")

        let later = start.addingTimeInterval(3_600)
        XCTAssertEqual(visits.enter(store15, at: later).map(\.name), ["geofence_entered"])
        let nextDay = visits.exit(store15, at: later.addingTimeInterval(25 * 3_600))
        XCTAssertEqual(nextDay.map(\.name), ["geofence_exited"])
        XCTAssertNil(nextDay[0].dwellSeconds)

        // The visits survive a restart of the app: iOS ends it between region events.
        let defaults = UserDefaults(suiteName: "onetrace-tests-\(UUID().uuidString)")!
        XCTAssertEqual(GeofenceVisits(defaults: defaults).enter(store15, at: start).count, 1)
        let relaunched = GeofenceVisits(defaults: defaults)
        XCTAssertEqual(relaunched.insideZones, [15])
        XCTAssertEqual(relaunched.exit(store15, at: start.addingTimeInterval(90)).first?.dwellSeconds, 90)
    }

    func testComingBackWithinThirtyMinutesOfLeavingIsNotReported() {
        let visits = visits()
        let start = Date(timeIntervalSince1970: 1_800_000_000)

        XCTAssertEqual(visits.enter(store15, at: start).count, 1)
        XCTAssertEqual(visits.exit(store15, at: start.addingTimeInterval(600)).count, 1)
        // GPS jitter at the border: 10 minutes later in and out again.
        XCTAssertTrue(visits.enter(store15, at: start.addingTimeInterval(1_200)).isEmpty)
        XCTAssertTrue(visits.wake(at: start.addingTimeInterval(1_600)).isEmpty)
        XCTAssertTrue(visits.exit(store15, at: start.addingTimeInterval(1_700)).isEmpty)
        XCTAssertTrue(visits.enter(store15, at: start.addingTimeInterval(1_700 + 29 * 60)).isEmpty, "30 minutes from the last exit")
        XCTAssertTrue(visits.exit(store15, at: start.addingTimeInterval(1_700 + 29 * 60 + 10)).isEmpty)

        let back = visits.enter(store15, at: start.addingTimeInterval(1_700 + 29 * 60 + 10 + 31 * 60))
        XCTAssertEqual(back.map(\.name), ["geofence_entered"])
    }

    func testParsesTheZoneListOfThePlatform() {
        let body = #"""
        {"version": "a1b2", "refreshHours": 12, "geofences": [
            {"id": 15, "externalId": "store_15", "name": "Store on Tverskaya", "latitude": 55.765, "longitude": 37.605, "radius": 150, "dwellSeconds": 300},
            {"id": 16, "externalId": null, "name": "Pickup point", "latitude": 55.7, "longitude": 37.5, "radius": 100, "dwellSeconds": 600},
            {"id": 17, "name": "Broken", "latitude": 95, "longitude": 37.5, "radius": 100}
        ]}
        """#
        let list = GeofenceList(json: body)

        XCTAssertEqual(list?.version, "a1b2")
        XCTAssertEqual(list?.refreshHours, 12)
        XCTAssertEqual(list?.geofences.map(\.id), [15, 16])
        XCTAssertEqual(list?.geofences.first, store15)
        XCTAssertNil(list?.geofences.last?.externalId)
        XCTAssertEqual(list?.zone(regionId: "onetrace.geofence.16")?.name, "Pickup point")
        XCTAssertNil(GeofenceList(json: "{}"))
    }

    func testTheListIsLoadedAtStartAndEveryTwelveHours() {
        let store = GeofenceStore(defaults: UserDefaults(suiteName: "onetrace-tests-\(UUID().uuidString)")!)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(store.due(now: now))

        store.list = GeofenceList(version: "a1", refreshHours: 12, geofences: [store15])
        store.loadedAt = now
        XCTAssertFalse(store.due(now: now.addingTimeInterval(11 * 3_600)))
        XCTAssertTrue(store.due(now: now.addingTimeInterval(12 * 3_600)))
        XCTAssertEqual(store.list?.geofences, [store15])
    }

    func testAPlanWithoutGeofencesIsAskedAgainOnlyAfterTheRefreshInterval() {
        let store = GeofenceStore(defaults: UserDefaults(suiteName: "onetrace-tests-\(UUID().uuidString)")!)
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        // 402: the plan has no mobile engagement. Not a list, but not asked again at every launch either.
        XCTAssertFalse(store.record(status: 402, body: "{}", etag: nil, now: now))
        XCTAssertNil(store.list)
        XCTAssertFalse(store.due(now: now.addingTimeInterval(3_600)))
        XCTAssertTrue(store.due(now: now.addingTimeInterval(12 * 3_600)))

        // No network and 429 are asked again at the next start.
        let later = now.addingTimeInterval(12 * 3_600)
        XCTAssertFalse(store.record(status: 429, body: "", etag: nil, now: later))
        XCTAssertFalse(store.record(status: 0, body: "", etag: nil, now: later))
        XCTAssertTrue(store.due(now: later.addingTimeInterval(60)))

        XCTAssertTrue(store.record(status: 200, body: #"{"version": "a1", "refreshHours": 12, "geofences": []}"#, etag: "a1", now: later))
        XCTAssertEqual(store.etag, "a1")
        XCTAssertFalse(store.due(now: later.addingTimeInterval(60)))
        XCTAssertTrue(store.record(status: 304, body: "", etag: nil, now: later.addingTimeInterval(13 * 3_600)))
    }

    func testWithoutAlwaysPermissionNothingIsEnabled() {
        #if canImport(CoreLocation) && os(iOS)
        // The simulator of CI has no location permission: after `setup` the reason is returned and no region is watched.
        OneTrace.setup(OneTraceConfig(writeKey: "cdp_wk_test", host: "https://crm.example.invalid", trackLifecycle: false))
        XCTAssertEqual(OneTraceLocation.enableGeofences(), .needsAlwaysPermission)
        let own = CLLocationManager().monitoredRegions.filter { $0.identifier.hasPrefix(GeofenceList.regionPrefix) || $0.identifier == GeofenceList.refreshRegionId }
        XCTAssertTrue(own.isEmpty)
        OneTraceLocation.disableGeofences()
        #else
        // On Linux there are no regions; before `OneTrace.setup` there is nothing to enable.
        XCTAssertEqual(OneTraceLocation.enableGeofences(), .notSetUp)
        #endif
        XCTAssertEqual(OneTraceLocation.maxMonitored, 18)
        OneTraceLocation.maxMonitored = 40
        XCTAssertEqual(OneTraceLocation.maxMonitored, 19)
        OneTraceLocation.maxMonitored = 18
    }
}
