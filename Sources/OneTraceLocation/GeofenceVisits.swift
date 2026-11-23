import Foundation

/// An event of a zone for `OneTrace.track`: only the zone ids and the time in it, never the device coordinates.
struct GeofenceEvent: Equatable {
    static let entered = "geofence_entered"
    static let dwelled = "geofence_dwelled"
    static let exited = "geofence_exited"

    let name: String
    let geofenceId: Int
    let externalId: String?
    let geofenceName: String
    let dwellSeconds: Int?

    var properties: [String: Any?] {
        var properties: [String: Any?] = [
            "geofence_id": geofenceId,
            "geofence_external_id": externalId,
            "geofence_name": geofenceName,
        ]
        if let dwellSeconds = dwellSeconds { properties["dwell_seconds"] = dwellSeconds }
        return properties
    }
}

/// Entries, stays and exits of zones, kept between launches (iOS wakes the app for a region event and may end it).
///
/// - `geofence_exited` has `dwell_seconds`, the time since the entry; without a recorded entry (the phone was off) it
///   comes without them.
/// - An entry older than 24 hours without an exit is dropped.
/// - Coming back into a zone less than 30 minutes after leaving it is GPS jitter at the border: neither that entry nor
///   the exit of that visit are reported, and the 30 minutes count from the last exit.
/// - `geofence_dwelled` comes once per visit at the first wake-up inside the zone after its `dwellSeconds`.
final class GeofenceVisits {
    static let rejoinWindow: TimeInterval = 30 * 60
    static let maxVisit: TimeInterval = 24 * 3600
    /// An exit reported twice by iOS (the exit and the state «outside») within this time is one exit.
    static let duplicateExit: TimeInterval = 120

    struct Visit: Codable, Equatable {
        var enteredAt: Double
        var quiet: Bool
        var dwelled: Bool
        var externalId: String?
        var name: String
        var dwellSeconds: Int
    }

    private struct State: Codable {
        var inside: [String: Visit] = [:]
        /// The last exit per zone id, UNIX seconds.
        var exits: [String: Double] = [:]
    }

    private let defaults: UserDefaults
    private let key = "geofence_visits"
    private var state: State

    init(defaults: UserDefaults) {
        self.defaults = defaults
        state = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(State.self, from: $0) } ?? State()
    }

    /// iOS reported the device inside the zone. Nothing when the visit is already known.
    func enter(_ zone: Geofence, at now: Date) -> [GeofenceEvent] {
        purge(now)
        let id = String(zone.id)
        guard state.inside[id] == nil else { return [] }

        let quiet = state.exits[id].map { now.timeIntervalSince1970 - $0 < Self.rejoinWindow } ?? false
        state.inside[id] = Visit(
            enteredAt: now.timeIntervalSince1970, quiet: quiet, dwelled: false,
            externalId: zone.externalId, name: zone.name, dwellSeconds: zone.dwellSeconds
        )
        save()
        return quiet ? [] : [event(GeofenceEvent.entered, zone.id, state.inside[id]!, dwell: nil)]
    }

    /// iOS reported the device outside. `confirmed` — a region exit; false for the state «outside», which only ends
    /// a known visit.
    func exit(_ zone: Geofence, at now: Date, confirmed: Bool = true) -> [GeofenceEvent] {
        purge(now)
        let id = String(zone.id)
        let seconds = now.timeIntervalSince1970

        guard let visit = state.inside.removeValue(forKey: id) else {
            // An exit without an entry: once, not again for the second report of the same exit.
            let recent = state.exits[id].map { seconds - $0 < Self.duplicateExit } ?? false
            guard confirmed, !recent else { return [] }
            state.exits[id] = seconds
            save()
            return [GeofenceEvent(name: GeofenceEvent.exited, geofenceId: zone.id, externalId: zone.externalId, geofenceName: zone.name, dwellSeconds: nil)]
        }

        state.exits[id] = seconds
        save()
        guard !visit.quiet else { return [] }
        return [event(GeofenceEvent.exited, zone.id, visit, dwell: Int(max(0, seconds - visit.enteredAt)))]
    }

    /// The SDK woke up: `geofence_dwelled` for the visits that passed the threshold of their zone. `inside` — the zones
    /// iOS still reports the device in; nil when it is not known.
    func wake(at now: Date, inside: Set<Int>? = nil) -> [GeofenceEvent] {
        purge(now)
        var events: [GeofenceEvent] = []
        for (id, visit) in state.inside where !visit.quiet && !visit.dwelled {
            guard let zoneId = Int(id), inside?.contains(zoneId) ?? true else { continue }
            let stayed = now.timeIntervalSince1970 - visit.enteredAt
            guard stayed >= Double(visit.dwellSeconds) else { continue }
            state.inside[id]?.dwelled = true
            events.append(event(GeofenceEvent.dwelled, zoneId, visit, dwell: Int(stayed)))
        }
        if !events.isEmpty { save() }
        return events.sorted { $0.geofenceId < $1.geofenceId }
    }

    /// Ids of the zones the device is in.
    var insideZones: Set<Int> { Set(state.inside.keys.compactMap(Int.init)) }

    func reset() {
        state = State()
        save()
    }

    private func event(_ name: String, _ zoneId: Int, _ visit: Visit, dwell: Int?) -> GeofenceEvent {
        GeofenceEvent(name: name, geofenceId: zoneId, externalId: visit.externalId, geofenceName: visit.name, dwellSeconds: dwell)
    }

    /// Drops entries older than 24 hours and exits past the 30-minute window.
    private func purge(_ now: Date) {
        let seconds = now.timeIntervalSince1970
        let before = (state.inside.count, state.exits.count)
        state.inside = state.inside.filter { seconds - $0.value.enteredAt < Self.maxVisit }
        state.exits = state.exits.filter { seconds - $0.value < Self.rejoinWindow }
        if before != (state.inside.count, state.exits.count) { save() }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(state) { defaults.set(data, forKey: key) }
    }
}
