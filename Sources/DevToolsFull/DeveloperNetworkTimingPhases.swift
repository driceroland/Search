import SwiftUI

/// The Timing tab's rows, named and grouped as Chrome's RequestTimingView
/// draws them, built from WebKit's ResourceTiming.
extension DeveloperNetworkTiming {
    enum TimingSection: String, CaseIterable {
        case scheduling = "Resource scheduling"
        case connection = "Connection start"
        case exchange = "Request/Response"
    }

    struct TimingPhase {
        let label: String
        let section: TimingSection
        /// Milliseconds from the request's start.
        let start: Double
        let end: Double
        let color: Color
    }

    struct ServerMetric {
        let name: String
        let description: String
        let duration: Double?
    }

    /// `timing` is WebKit's Network.ResourceTiming: startTime and fetchStart
    /// are timestamps in seconds, the rest are milliseconds after fetchStart
    /// (or -1 when that phase didn't happen).
    static func phases(for request: DeveloperToolsSession.Request, timing: [String: Double]) -> [TimingPhase] {
        guard let started = request.started, started.isFinite else { return [] }
        let end = request.ended.flatMap { $0.isFinite && $0 >= started ? ($0 - started) * 1_000 : nil }
        guard let fetch = timing["fetchStart"], fetch > 0, let requestStart = timing["requestStart"], requestStart >= 0 else {
            return fallback(request, started: started, end: end)
        }
        let base = (fetch - (timing["startTime"].flatMap { $0 > 0 ? $0 : nil } ?? started)) * 1_000
        func at(_ name: String) -> Double? {
            guard let value = timing[name], value >= 0 else { return nil }
            return base + value
        }
        var phases: [TimingPhase] = []
        func add(_ label: String, _ section: TimingSection, _ start: Double?, _ finish: Double?, _ color: Color) {
            guard let start, let finish, finish >= start else { return }
            phases.append(TimingPhase(label: label, section: section, start: start, end: finish, color: color))
        }
        let dnsStart = at("domainLookupStart"), dnsEnd = at("domainLookupEnd")
        let connectStart = at("connectStart"), connectEnd = at("connectEnd")
        let secure = at("secureConnectionStart")
        let sent = at("requestStart")
        let response = at("responseStart")
        let blocking = dnsStart ?? connectStart ?? sent
        add("Queueing", .scheduling, 0, max(0, base), .gray.opacity(0.5))
        add("Stalled", .scheduling, max(0, base), blocking, .gray)
        add("DNS lookup", .connection, dnsStart, dnsEnd, .teal)
        add("Initial connection", .connection, connectStart, connectEnd, .orange)
        add("SSL", .connection, secure, connectEnd, .purple)
        add("Request sent", .exchange, sent, sent, .green.opacity(0.7))
        add("Waiting for server response", .exchange, sent, response ?? end, .green)
        add("Content download", .exchange, response, at("responseEnd") ?? end, .blue)
        return phases
    }

    /// Without ResourceTiming (cached loads, WebSockets), the three spans the
    /// list's own timestamps support.
    private static func fallback(_ request: DeveloperToolsSession.Request, started: Double, end: Double?) -> [TimingPhase] {
        segments(for: request).compactMap { segment in
            let start = (segment.start - started) * 1_000, finish = (segment.end - started) * 1_000
            switch segment.phase {
            case .beforeSend: return TimingPhase(label: "Stalled", section: .scheduling, start: start, end: finish, color: .gray)
            case .waiting: return TimingPhase(label: "Waiting for server response", section: .exchange, start: start, end: finish, color: .green)
            case .receiving: return TimingPhase(label: "Content download", section: .exchange, start: start, end: finish, color: .blue)
            case .total: return nil
            }
        }
    }

    /// The Server-Timing response header, as Chrome's ServerTiming parses it:
    /// `name;dur=12.3;desc="text"`, entries separated by commas.
    static func serverTiming(_ headers: [DeveloperRequestDetails.Header]) -> [ServerMetric] {
        headers.filter { $0.name.caseInsensitiveCompare("server-timing") == .orderedSame }
            .flatMap { $0.value.split(separator: ",") }
            .compactMap { entry in
                let parts = entry.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
                guard let name = parts.first, !name.isEmpty else { return nil }
                var duration: Double?
                var description = ""
                for parameter in parts.dropFirst() {
                    let pair = parameter.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                    guard pair.count == 2 else { continue }
                    switch pair[0].lowercased() {
                    case "dur": duration = Double(pair[1])
                    case "desc": description = pair[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                    default: break
                    }
                }
                return ServerMetric(name: name, description: description, duration: duration)
            }
    }
}
