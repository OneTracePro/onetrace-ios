import Foundation

/// The timer of a message as text: «until 18:00» for the notification body without the Notification Content
/// Extension, and the countdown of the expanded notification.
public enum TimerText {
    /// «до 18:00» — the end by the device clock (12 or 24 hours as set on the phone) in the device language; with the
    /// day when it is not today.
    public static func until(_ end: Date, now: Date = Date(), locale: Locale = .current, timeZone: TimeZone = .current, language: String? = nil) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let sameDay = calendar.isDate(end, inSameDayAs: now)

        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        if let format = DateFormatter.dateFormat(fromTemplate: sameDay ? "jmm" : "dMMMjmm", options: 0, locale: locale) {
            formatter.dateFormat = format
        } else {
            formatter.timeStyle = .short
            formatter.dateStyle = sameDay ? .none : .short
        }

        let strings = PushStrings.forLanguage(language)
        let template = sameDay ? strings.untilTime : strings.untilDate
        return template.replacingOccurrences(of: "%@", with: formatter.string(from: end))
    }

    /// The body with the end of the timer: «Sale on everything · until 18:00». Unchanged when the timer is over.
    public static func appending(to body: String, end: Date, now: Date = Date(), locale: Locale = .current, timeZone: TimeZone = .current, language: String? = nil) -> String {
        guard end > now else { return body }
        let suffix = Self.until(end, now: now, locale: locale, timeZone: timeZone, language: language)
        return body.isEmpty ? suffix : body + " · " + suffix
    }

    /// The time left: `5:07`, `1:05:07`, `49:05:07`; nil when it is over.
    public static func countdown(_ remaining: TimeInterval) -> String? {
        guard remaining > 0 else { return nil }
        let total = Int(remaining.rounded(.up))
        let hours = total / 3600
        let minutes = total % 3600 / 60
        let seconds = total % 60
        let pad = { (value: Int) in value < 10 ? "0\(value)" : "\(value)" }
        return hours > 0 ? "\(hours):\(pad(minutes)):\(pad(seconds))" : "\(minutes):\(pad(seconds))"
    }
}

/// Texts of rich notifications in the platform's languages; English for other languages.
public struct PushStrings: Equatable {
    /// «until {time}» for an end today.
    public let untilTime: String
    /// «until {date and time}» for another day.
    public let untilDate: String
    /// The countdown is over.
    public let ended: String

    public static let all: [String: PushStrings] = [
        "en": PushStrings(untilTime: "until %@", untilDate: "until %@", ended: "Time is up"),
        "ru": PushStrings(untilTime: "до %@", untilDate: "до %@", ended: "Время вышло"),
        "de": PushStrings(untilTime: "bis %@", untilDate: "bis %@", ended: "Abgelaufen"),
        "uz": PushStrings(untilTime: "%@ gacha", untilDate: "%@ gacha", ended: "Vaqt tugadi"),
        "tr": PushStrings(untilTime: "%@ saatine kadar", untilDate: "%@ tarihine kadar", ended: "Süre doldu"),
        "es": PushStrings(untilTime: "hasta las %@", untilDate: "hasta el %@", ended: "Se acabó el tiempo"),
        "fr": PushStrings(untilTime: "jusqu’à %@", untilDate: "jusqu’au %@", ended: "Temps écoulé"),
        "it": PushStrings(untilTime: "fino alle %@", untilDate: "fino al %@", ended: "Tempo scaduto"),
        "pt": PushStrings(untilTime: "até as %@", untilDate: "até %@", ended: "O tempo acabou"),
        "zh": PushStrings(untilTime: "截至 %@", untilDate: "截至 %@", ended: "已结束"),
    ]

    /// `language` such as `de`, `pt-BR` or `zh-Hans-CN`; nil — the first preferred language.
    public static func forLanguage(_ language: String?) -> PushStrings {
        let tag = (language ?? Locale.preferredLanguages.first ?? "en").lowercased()
        let code = tag.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? "en"
        return all[code] ?? all["en"]!
    }
}
