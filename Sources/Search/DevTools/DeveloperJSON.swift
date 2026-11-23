import Foundation

// Reading the loose `[String: Any]` the inspector protocol and the page's
// scripts answer with. Each reader means exactly what the cast it stands
// for means, so `params.int("nodeId")` can replace
// `params["nodeId"] as? Int` without changing what is accepted.

extension Dictionary where Key == String {
    /// `self[key] as? String`.
    func string(_ key: String) -> String? { self[key] as? String }

    /// `self[key] as? Int`: a whole number only (1.5 is nil, as the cast is).
    func int(_ key: String) -> Int? { self[key] as? Int }

    /// Any number, whole or not, as a Double: `(self[key] as? NSNumber)?.doubleValue`.
    func double(_ key: String) -> Double? { (self[key] as? NSNumber)?.doubleValue }

    /// `self[key] as? Bool`.
    func bool(_ key: String) -> Bool? { self[key] as? Bool }

    /// `self[key] as? Bool == true`: the protocol's flags, absent meaning off.
    func flag(_ key: String) -> Bool { self[key] as? Bool == true }

    /// `self[key] as? [String: Any]`: a nested object.
    func object(_ key: String) -> [String: Any]? { self[key] as? [String: Any] }

    /// `self[key] as? [[String: Any]]`: a list of objects.
    func objects(_ key: String) -> [[String: Any]]? { self[key] as? [[String: Any]] }

    /// `self[key] as? [String]`.
    func strings(_ key: String) -> [String]? { self[key] as? [String] }
}

/// Loose protocol values outside a dictionary.
enum DeveloperProtocolValue {
    /// Any number as a Double: `(value as? NSNumber)?.doubleValue`.
    static func number(_ value: Any?) -> Double? { (value as? NSNumber)?.doubleValue }

    /// A number, or a string that reads as one ("12.5", and "Infinity"
    /// in any case, as CSS and the animation protocol write it).
    static func numeric(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber: return number.doubleValue
        case let string as String:
            if string.lowercased() == "infinity" { return .infinity }
            return Double(string)
        default: return nil
        }
    }
}
