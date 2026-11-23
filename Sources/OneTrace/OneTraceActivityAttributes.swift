import Foundation
#if canImport(ActivityKit) && os(iOS)
import ActivityKit
#endif

/// The Live Activity type of OneTrace (iOS 16.1+): an order status, a delivery, a countdown. The platform starts,
/// updates and ends it through APNs with `attributes-type: OneTraceActivityAttributes`; draw it in your widget
/// extension with `ActivityConfiguration(for: OneTraceActivityAttributes.self)`.
public struct OneTraceActivityAttributes: Codable, Hashable, Sendable {
    /// The state the platform sends in `content-state`.
    public struct ContentState: Codable, Hashable, Sendable {
        public var title: String
        public var status: String?
        /// The current step, from 1 to `steps.count`: `steps[step - 1]` is the current one (the platform sends 1–6).
        public var step: Int?
        /// Up to 6 step names, for example «Accepted», «Packed», «On the way», «Delivered».
        public var steps: [String]?
        /// From 0 to 1.
        public var progress: Double?
        /// The end of the countdown: `Text(timerInterval: Date()...endsAt)`.
        public var endsAt: Date?
        /// Your own values: an order number, a courier name.
        public var data: [String: String]

        public init(title: String, status: String? = nil, step: Int? = nil, steps: [String]? = nil, progress: Double? = nil, endsAt: Date? = nil, data: [String: String] = [:]) {
            self.title = title
            self.status = status
            self.step = step
            self.steps = steps
            self.progress = progress
            self.endsAt = endsAt
            self.data = data
        }

        enum CodingKeys: String, CodingKey {
            case title, status, step, steps, progress, endsAt, data
        }

        /// `endsAt` is UNIX seconds whatever date strategy the decoder has: the platform sends it so.
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            title = try container.decode(String.self, forKey: .title)
            status = try container.decodeIfPresent(String.self, forKey: .status)
            step = try container.decodeIfPresent(Int.self, forKey: .step)
            steps = try container.decodeIfPresent([String].self, forKey: .steps)
            progress = try container.decodeIfPresent(Double.self, forKey: .progress)
            endsAt = try container.decodeIfPresent(Double.self, forKey: .endsAt).map { Date(timeIntervalSince1970: $0) }
            data = try container.decodeIfPresent([String: String].self, forKey: .data) ?? [:]
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(title, forKey: .title)
            try container.encodeIfPresent(status, forKey: .status)
            try container.encodeIfPresent(step, forKey: .step)
            try container.encodeIfPresent(steps, forKey: .steps)
            try container.encodeIfPresent(progress, forKey: .progress)
            try container.encodeIfPresent(endsAt?.timeIntervalSince1970, forKey: .endsAt)
            try container.encode(data, forKey: .data)
        }
    }

    /// The kind of activity, as in the message template: `order`, `delivery`, `sale`.
    public var type: String
    /// Which one: the order number. The platform updates the activity with this type and key.
    public var key: String

    public init(type: String, key: String) {
        self.type = type
        self.key = key
    }
}

#if canImport(ActivityKit) && os(iOS)
@available(iOS 16.1, *)
extension OneTraceActivityAttributes: ActivityAttributes {}
#endif
