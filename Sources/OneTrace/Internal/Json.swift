import Foundation

/// Event properties and traits as JSON values: dates become ISO 8601 UTC strings, unknown values their description.
enum Json {
    static func object(_ dictionary: [String: Any?]) -> [String: Any] {
        dictionary.mapValues { value($0) }
    }

    static func value(_ value: Any?) -> Any {
        // Numbers from Objective-C, Flutter and React Native are NSNumber objects, and `NSNumber(1) as? Bool` succeeds:
        // tell booleans from numbers by the object itself.
        if let object = value, type(of: object) is NSNumber.Type, let number = object as? NSNumber {
            return isBoolean(number) ? number.boolValue as Any : number
        }

        switch value {
        case nil, is NSNull: return NSNull()
        case let v as String: return v
        case let v as Bool: return v
        case let v as Int: return v
        case let v as Double: return v
        case let v as Float: return Double(v)
        case let v as NSNumber: return v
        case let v as Date: return iso(v)
        case let v as URL: return v.absoluteString
        case let v as [String: Any?]: return object(v)
        case let v as [Any?]: return v.map { self.value($0) }
        case let v?: return String(describing: v)
        }
    }

    static func isBoolean(_ number: NSNumber) -> Bool {
        #if canImport(Darwin)
        return CFGetTypeID(number) == CFBooleanGetTypeID()
        #else
        return String(cString: number.objCType) == "c"
        #endif
    }

    static func iso(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        return formatter.string(from: date)
    }
}
