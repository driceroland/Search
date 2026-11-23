import Foundation

/// Small readers the measuring panels (Performance, Network, Lighthouse,
/// Application and the rest) share for what WebKit and page scripts send.
enum DeveloperMeasure {
    /// A JSON number as a Double, or nil when it is missing, not a number,
    /// or not finite.
    static func finite(_ value: Any?) -> Double? {
        guard let value = (value as? NSNumber)?.doubleValue, value.isFinite else { return nil }
        return value
    }

    static func bundled<Value: Decodable>(_ type: Value.Type, named name: String) -> Value? {
        DevToolsResources.decode(type, named: name)
    }

    /// Wall-clock time to the millisecond, local time, as Chrome's Time
    /// columns show it (Network's messages, the Protocol monitor).
    static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()
}
