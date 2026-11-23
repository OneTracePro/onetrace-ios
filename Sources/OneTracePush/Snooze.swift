import Foundation

/// The delay of «Remind me later» (`snooze_minutes` of the button): minutes, or tomorrow at 9:00 by the phone clock.
public enum SnoozeDelay: Equatable {
    case minutes(Int)
    case tomorrowMorning

    public static let morningHour = 9

    /// `60`, `"180"`, or a word starting with `tomorrow` (`"tomorrow"`, `"tomorrow_9"`); nil for anything else.
    public init?(_ value: Any?) {
        if let text = value as? String {
            let word = text.trimmingCharacters(in: .whitespaces).lowercased()
            if word.hasPrefix("tomorrow") {
                self = .tomorrowMorning
                return
            }
            guard let minutes = Int(word) else { return nil }
            self.init(minutes: minutes)
            return
        }
        if let minutes = value as? Int {
            self.init(minutes: minutes)
            return
        }
        if let minutes = value as? Double {
            self.init(minutes: Int(minutes))
            return
        }
        return nil
    }

    private init?(minutes: Int) {
        guard minutes > 0 else { return nil }
        self = .minutes(min(minutes, 7 * 24 * 60))
    }

    /// When the copy is shown: an interval for minutes, a calendar date for tomorrow 9:00 in the time zone of `calendar`
    /// (the phone's), so the trigger keeps the wall clock time even across a daylight saving change.
    public func trigger(now: Date = Date(), calendar: Calendar = .current) -> SnoozeTrigger {
        switch self {
        case .minutes(let minutes):
            return .interval(TimeInterval(minutes * 60))
        case .tomorrowMorning:
            let today = calendar.startOfDay(for: now)
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) ?? now.addingTimeInterval(86_400)
            var components = calendar.dateComponents([.year, .month, .day], from: tomorrow)
            components.hour = Self.morningHour
            components.minute = 0
            return .calendar(components)
        }
    }
}

/// The trigger of the local copy: `UNTimeIntervalNotificationTrigger` or `UNCalendarNotificationTrigger`.
public enum SnoozeTrigger: Equatable {
    case interval(TimeInterval)
    case calendar(DateComponents)
}
