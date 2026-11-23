import Foundation

/// Which zones to hand to iOS: it watches at most 20 regions for an app. The nearest zones (18 by default) and a
/// «refresh region» around the device: leaving it, the SDK picks the nearest zones again for the new place.
struct GeofenceSelector {
    /// The smallest refresh region: iOS does not report smaller regions reliably.
    static let minRefreshRadius: Double = 200

    let maxZones: Int
    let maxRadius: Double

    init(maxZones: Int = 18, maxRadius: Double = 100_000) {
        self.maxZones = max(1, maxZones)
        self.maxRadius = maxRadius
    }

    struct Selection: Equatable {
        /// The nearest zones, the nearest first.
        let zones: [Geofence]
        /// The region around `center` to leave before another zone can come close; nil when every zone is watched.
        let refreshRadius: Double?
        let center: GeoPoint?
    }

    /// Without a location — the first zones of the list until the location comes.
    func select(_ zones: [Geofence], around location: GeoPoint?) -> Selection {
        guard let location = location else {
            return Selection(zones: Array(zones.prefix(maxZones)), refreshRadius: nil, center: nil)
        }

        // The distance to the edge of the zone: a big zone is near once its border is.
        let ranked: [RankedZone] = zones.map { (zone: Geofence) -> RankedZone in
            let distance: Double = location.distance(to: zone.center)
            return RankedZone(zone: zone, edge: max(0, distance - zone.radius))
        }
        let sorted: [RankedZone] = ranked.sorted { (left: RankedZone, right: RankedZone) -> Bool in
            if left.edge == right.edge { return left.zone.id < right.zone.id }
            return left.edge < right.edge
        }

        let chosen: [Geofence] = sorted.prefix(maxZones).map { (ranked: RankedZone) -> Geofence in ranked.zone }
        guard sorted.count > maxZones else {
            return Selection(zones: chosen, refreshRadius: nil, center: location)
        }

        // Up to the edge of the nearest zone left out: before reaching it, the device leaves the refresh region.
        let nextEdge = sorted[maxZones].edge
        let radius = min(maxRadius, max(Self.minRefreshRadius, nextEdge))
        return Selection(zones: chosen, refreshRadius: radius, center: location)
    }

    /// A zone with the distance from the device to its edge.
    private struct RankedZone {
        let zone: Geofence
        let edge: Double
    }
}
