import Foundation

/// Identifiers and SDK state kept between launches.
final class Storage {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = UserDefaults(suiteName: "pro.onetrace.sdk") ?? .standard) {
        self.defaults = defaults
    }

    /// Random id of this installation; also the `mobile_push` identity of the profile. Never changes.
    lazy var installationId: String = {
        if let id = defaults.string(forKey: "installation_id") { return id }
        let id = UUID().uuidString.lowercased()
        defaults.set(id, forKey: "installation_id")
        return id
    }()

    var anonymousId: String {
        get { defaults.string(forKey: "anonymous_id") ?? newAnonymousId() }
        set { defaults.set(newValue, forKey: "anonymous_id") }
    }

    var userId: String? {
        get { defaults.string(forKey: "user_id") }
        set { defaults.set(newValue, forKey: "user_id") }
    }

    var appVersion: String? {
        get { defaults.string(forKey: "app_version") }
        set { defaults.set(newValue, forKey: "app_version") }
    }

    var appBuild: String? {
        get { defaults.string(forKey: "app_build") }
        set { defaults.set(newValue, forKey: "app_build") }
    }

    var pushToken: String? {
        get { defaults.string(forKey: "push_token") }
        set { defaults.set(newValue, forKey: "push_token") }
    }

    var pushProvider: String? {
        get { defaults.string(forKey: "push_provider") }
        set { defaults.set(newValue, forKey: "push_provider") }
    }

    /// Fingerprint of the last device registration the platform accepted.
    var registration: String? {
        get { defaults.string(forKey: "registration") }
        set { defaults.set(newValue, forKey: "registration") }
    }

    @discardableResult
    func newAnonymousId() -> String {
        let id = UUID().uuidString.lowercased()
        anonymousId = id
        return id
    }
}
