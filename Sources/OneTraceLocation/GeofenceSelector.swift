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
        let sorted = zones
            .map { (zone: $0, edge: max(0, location.distance(to: $0.center) - $0.radius)) }
            .sorted { $0.edge == $1.edge ? $0.zone.id < $1.zone.id : $0.edge < $1.edge }

        let chosen = sorted.prefix(maxZones).map(\.zone)
        guard sorted.count > maxZones else {
            return Selection(zones: chosen, refreshRadius: nil, center: location)
        }

        // Up to the edge of the nearest zone left out: before reaching it, the device leaves the refresh region.
        let nextEdge = sorted[maxZones].edge
        let radius = min(maxRadius, max(Self.minRefreshRadius, nextEdge))
        return Selection(zones: chosen, refreshRadius: radius, center: location)
    }
}
