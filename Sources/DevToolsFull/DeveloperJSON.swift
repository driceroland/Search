import Foundation

// Reading the loose `[String: Any]` the inspector protocol and the page's
// scripts answer with, and writing numbers, bytes and times as Chrome's
// DevTools does: the one place for both, which each panel used to have a
// copy of. Each reader means exactly what the cast it stands for means, so
// `params.int("nodeId")` can replace `params["nodeId"] as? Int` without
// changing what is accepted.

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

    /// A number that is finite and not negative: a time or a size.
    static func measure(_ value: Any?) -> Double? {
        guard let value = (value as? NSNumber)?.doubleValue, value.isFinite, value >= 0 else { return nil }
        return value
    }

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

/// Small readers the measuring panels share for what WebKit and page
/// scripts send.
enum DeveloperMeasure {
    /// A JSON number as a Double, or nil when it is missing, not a number,
    /// or not finite.
    static func finite(_ value: Any?) -> Double? {
        guard let value = (value as? NSNumber)?.doubleValue, value.isFinite else { return nil }
        return value
    }

    /// Wall-clock time to the millisecond, local time, as Chrome's Time
    /// columns show it.
    static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()
}

/// Numbers, bytes and times as Chrome's DevTools writes them.
enum DeveloperFormat {
    private static func formatter(_ digits: Int) -> NumberFormatter {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.groupingSeparator = ","
        formatter.groupingSize = 3
        formatter.minimumFractionDigits = digits
        formatter.maximumFractionDigits = digits
        return formatter
    }

    private static let whole = formatter(0)
    private static let tenths = formatter(1)
    private static let hundredths = formatter(2)

    static func integer(_ value: Double) -> String {
        whole.string(from: NSNumber(value: value.rounded())) ?? String(Int(value.rounded()))
    }

    static func decimal(_ value: Double, digits: Int) -> String {
        let formatter = digits <= 0 ? whole : digits == 1 ? tenths : hundredths
        // No "-0.0" for a value a hair under zero.
        let shown = abs(value) < 0.5 * pow(10, -Double(max(0, digits))) ? 0 : value
        return formatter.string(from: NSNumber(value: shown)) ?? String(shown)
    }

    /// Chrome's bytesToString: decimal units, a tenth under 100 of a unit.
    static func bytes(_ value: Double) -> String {
        let value = max(0, value)
        if value < 1000 { return integer(value) + " B" }
        let units = ["kB", "MB", "GB", "TB"]
        var scaled = value / 1000
        var unit = 0
        while scaled >= 1000, unit < units.count - 1 {
            scaled /= 1000
            unit += 1
        }
        return (scaled < 100 ? decimal(scaled, digits: 1) : integer(scaled)) + " " + units[unit]
    }

    static func bytes(_ value: Int) -> String { bytes(Double(value)) }

    /// Memory's sizes: always megabytes, a tenth.
    static func megabytes(_ bytes: Int) -> String { String(format: "%.1f MB", Double(bytes) / 1_000_000) }

    /// Milliseconds, then seconds from 1,000 ms, as DevTools' summaries.
    static func seconds(_ milliseconds: Double) -> String {
        milliseconds < 1_000 ? "\(Int(milliseconds.rounded())) ms"
            : (milliseconds / 1_000).formatted(.number.precision(.fractionLength(2))) + " s"
    }

    /// Milliseconds with a tenth (two under 10 ms, `fine`), as the request
    /// timing rows write them.
    static func milliseconds(_ milliseconds: Double, fine: Bool = false) -> String {
        milliseconds.formatted(.number.precision(.fractionLength(milliseconds < 10 && milliseconds > 0 ? (fine ? 2 : 1) : (fine ? 1 : 0)))) + " ms"
    }

    /// A long span: ms, s, min, hrs, days (a cookie's lifetime).
    static func span(_ milliseconds: Double) -> String {
        guard milliseconds.isFinite else { return "-" }
        if milliseconds == 0 { return "0" }
        if milliseconds < 1_000 { return String(format: "%.0f ms", milliseconds) }
        let seconds = milliseconds / 1_000
        if seconds < 60 { return String(format: "%.2f s", seconds) }
        let minutes = seconds / 60
        if minutes < 60 { return String(format: "%.1f min", minutes) }
        let hours = minutes / 60
        if hours < 24 { return String(format: "%.1f hrs", hours) }
        return String(format: "%.1f days", hours / 24)
    }
}
