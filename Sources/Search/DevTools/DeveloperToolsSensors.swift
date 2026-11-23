import Foundation
import WebKit

@MainActor
final class DeveloperToolsSensors {
    typealias Command = @MainActor (String, [String: Any]) async throws -> [String: Any]

    enum Location: Equatable {
        case coordinates(latitude: Double, longitude: Double, accuracy: Double)
        case unavailable

        fileprivate var payload: [String: Any]? {
            switch self {
            case .unavailable: return ["unavailable": true]
            case let .coordinates(latitude, longitude, accuracy):
                guard (-90...90).contains(latitude), (-180...180).contains(longitude),
                      accuracy.isFinite, accuracy >= 0 else { return nil }
                return ["latitude": latitude, "longitude": longitude, "accuracy": accuracy]
            }
        }
    }

    struct Orientation: Equatable {
        let alpha: Double
        let beta: Double
        let gamma: Double

        fileprivate var payload: [String: Double]? {
            guard (0...360).contains(alpha), (-180...180).contains(beta),
                  (-90...90).contains(gamma) else { return nil }
            return ["alpha": alpha == 360 ? 0 : alpha, "beta": beta, "gamma": gamma]
        }
    }

    struct State: Equatable {
        var location: Location? = nil
        var orientation: Orientation? = nil
        /// Chrome applies a location's timezone ID and locale with it.
        var timezone: String? = nil
        var locale: String? = nil

        fileprivate var zonePayload: [String: Any]? {
            guard timezone != nil || locale != nil else { return nil }
            return ["timezone": timezone as Any? ?? NSNull(), "locale": locale as Any? ?? NSNull()]
        }
    }

    enum Failure: LocalizedError {
        case invalidLocation, invalidOrientation, noWebPage, pageChanged, invalidTimezone, invalidLocale

        var errorDescription: String? {
            switch self {
            case .invalidTimezone: return "Enter a valid timezone ID, such as Europe/Berlin."
            case .invalidLocale: return "Enter a valid locale, such as de-DE."
            case .invalidLocation: return "Enter a valid latitude, longitude, and nonnegative accuracy."
            case .invalidOrientation: return "Enter alpha from 0 to 360°, beta from −180 to 180°, and gamma from −90 to 90°."
            case .noWebPage: return "Open a web page to use simulated sensors."
            case .pageChanged: return "The page changed before the sensor overrides could be applied."
            }
        }
    }

    private let key = "__perchSensors_" + UUID().uuidString
    private weak var web: WKWebView?
    private var origin: String?
    private var bootstrapCommand: Command?
    private var pending: Task<Void, Error>?
    private var sequence = 0
    private(set) var repeatsOnReload = false

    /// The command must target this view's page. Keep any captured session weak
    /// and call reset before disconnecting it.
    func apply(_ state: State, to web: WKWebView, command: Command? = nil) async throws {
        guard state.location != nil || state.orientation != nil || state.zonePayload != nil else { await reset(); return }
        let location = state.location?.payload
        let orientation = state.orientation?.payload
        guard state.location == nil || location != nil else { throw Failure.invalidLocation }
        guard state.orientation == nil || orientation != nil else { throw Failure.invalidOrientation }
        if let timezone = state.timezone, TimeZone(identifier: timezone) == nil { throw Failure.invalidTimezone }
        if let locale = state.locale, !Self.validLocale(locale) { throw Failure.invalidLocale }
        guard let origin = Self.webOrigin(web.url) else { throw Failure.noWebPage }
        let input: [String: Any] = [
            "key": key,
            "origin": origin,
            "location": location as Any? ?? NSNull(),
            "orientation": orientation as Any? ?? NSNull(),
            "zone": state.zonePayload as Any? ?? NSNull(),
        ]
        let json = try JSONSerialization.data(withJSONObject: input)
        let source = "(\(Self.install))(\(String(decoding: json, as: UTF8.self)))"

        let (number, task) = enqueue { [self] in
            try Task.checkCancellation()
            if self.web !== web || self.origin != origin { await restore() }
            try Task.checkCancellation()
            self.web = web
            self.origin = origin
            do {
                let applied = try await web.evaluateJavaScript(source, in: nil, contentWorld: .page)
                guard (applied as? Bool) == true else { throw Failure.pageChanged }
                try Task.checkCancellation()
                if let command {
                    // Record the command before awaiting its response. A reply
                    // can be lost after WebKit has already stored the script.
                    bootstrapCommand = command
                    do {
                        _ = try await command("Page.setBootstrapScript", ["source": source])
                        repeatsOnReload = true
                    } catch {
                        let cleanup = Task { await removeBootstrap() }
                        await cleanup.value
                    }
                } else {
                    await removeBootstrap()
                }
                try Task.checkCancellation()
            } catch {
                let cleanup = Task { await restore() }
                await cleanup.value
                throw error
            }
        }
        defer { if sequence == number { pending = nil } }
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func reset() async {
        guard pending != nil || web != nil || bootstrapCommand != nil else { return }
        pending?.cancel()
        let (number, task) = enqueue { [self] in await restore() }
        _ = await task.result
        if sequence == number { pending = nil }
    }

    private func enqueue(_ work: @escaping @MainActor () async throws -> Void) -> (Int, Task<Void, Error>) {
        let previous = pending
        sequence += 1
        let task = Task { @MainActor in
            _ = await previous?.result
            try await work()
        }
        pending = task
        return (sequence, task)
    }

    private func removeBootstrap() async {
        if let bootstrapCommand { _ = try? await bootstrapCommand("Page.setBootstrapScript", [:]) }
        bootstrapCommand = nil
        repeatsOnReload = false
    }

    private func restore() async {
        await removeBootstrap()
        if let web {
            _ = try? await web.callAsyncJavaScript(
                "window[Symbol.for(key)]?.dispose();",
                arguments: ["key": key], in: nil, contentWorld: .page
            )
        }
        web = nil
        origin = nil
    }

    static func validLocale(_ text: String) -> Bool {
        text.range(of: #"^[A-Za-z]{2,8}(-[A-Za-z0-9]{1,8})*$"#, options: .regularExpression) != nil
    }

    private static func webOrigin(_ url: URL?) -> String? {
        guard let url, let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http", let host = url.host(), !host.isEmpty else { return nil }
        let authority = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        return "\(scheme)://\(authority)" + (url.port.map { ":\($0)" } ?? "")
    }

    // Only the selected top document uses fixtures. The per-page bootstrap
    // can also run in frames and after navigating, so check both boundaries.
    private static let install = DevToolsResources.script("DeveloperToolsSensors-install.js")
}
