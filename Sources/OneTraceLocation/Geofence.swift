import Foundation

/// A zone of the project from `GET /geofences`: a circle with a name, an optional external id and the time after which
/// a stay counts as «dwelled».
struct Geofence: Codable, Equatable {
    let id: Int
    let externalId: String?
    let name: String
    let latitude: Double
    let longitude: Double
    /// Meters.
    let radius: Double
    let dwellSeconds: Int

    var center: GeoPoint { GeoPoint(latitude: latitude, longitude: longitude) }

    /// The identifier of the CoreLocation region.
    var regionId: String { GeofenceList.regionPrefix + String(id) }
}

/// The answer of `GET /geofences`: `{version, refreshHours, geofences: [...]}`.
struct GeofenceList: Codable, Equatable {
    static let regionPrefix = "onetrace.geofence."
    static let refreshRegionId = "onetrace.refresh"

    let version: String
    let refreshHours: Int
    let geofences: [Geofence]

    init(version: String, refreshHours: Int, geofences: [Geofence]) {
        self.version = version
        self.refreshHours = refreshHours
        self.geofences = geofences
    }

    /// Skips zones that are not valid instead of failing the whole list.
    init?(json body: String) {
        guard let json = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let zones = json["geofences"] as? [Any] else { return nil }

        version = (json["version"] as? String) ?? ""
        refreshHours = max(1, Self.int(json["refreshHours"]) ?? 12)
        geofences = zones.compactMap { item in
            guard let zone = item as? [String: Any], let id = Self.int(zone["id"]),
                  let latitude = Self.double(zone["latitude"]), let longitude = Self.double(zone["longitude"]),
                  let radius = Self.double(zone["radius"]), radius > 0,
                  (-90...90).contains(latitude), (-180...180).contains(longitude) else { return nil }
            let external = (zone["externalId"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return Geofence(
                id: id, externalId: external, name: (zone["name"] as? String) ?? "", latitude: latitude, longitude: longitude,
                radius: radius, dwellSeconds: max(0, Self.int(zone["dwellSeconds"]) ?? 300)
            )
        }
    }

    func zone(regionId: String) -> Geofence? {
        geofences.first { $0.regionId == regionId }
    }

    private static func int(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? Double { return Int(value) }
        if let value = value as? String { return Int(value) }
        return nil
    }

    private static func double(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        if let value = value as? String { return Double(value) }
        return nil
    }
}

/// A point on the Earth, without CoreLocation (the selection is tested on Linux).
struct GeoPoint: Equatable {
    let latitude: Double
    let longitude: Double

    /// Meters along the surface (haversine).
    func distance(to other: GeoPoint) -> Double {
        let radians: Double = Double.pi / 180
        let dLat: Double = (other.latitude - latitude) * radians
        let dLon: Double = (other.longitude - longitude) * radians
        let sinLat: Double = sin(dLat / 2)
        let sinLon: Double = sin(dLon / 2)
        let cosines: Double = cos(latitude * radians) * cos(other.latitude * radians)
        let a: Double = sinLat * sinLat + cosines * sinLon * sinLon
        let earthRadius: Double = 6_371_000
        return 2 * earthRadius * atan2(sqrt(a), sqrt(1 - a))
    }
}
