import Foundation
import WebKit

/// The existing answers, kept separately for each kind of request.
enum CaptureChoices {
    enum Kind: CaseIterable, Identifiable {
        case camera, microphone, cameraAndMicrophone, location, notifications
        var id: Self { self }
        var title: String {
            switch self {
            case .camera: return "Camera"
            case .microphone: return "Microphone"
            case .cameraAndMicrophone: return "Camera and microphone together"
            case .location: return "Location"
            case .notifications: return "Notifications"
            }
        }
        var suffix: String {
            switch self {
            case .camera: return "\(WKMediaCaptureType.camera.rawValue)"
            case .microphone: return "\(WKMediaCaptureType.microphone.rawValue)"
            case .cameraAndMicrophone: return "\(WKMediaCaptureType.cameraAndMicrophone.rawValue)"
            case .location: return "location"
            case .notifications: return "notifications"
            }
        }
        var media: Bool { self == .camera || self == .microphone || self == .cameraAndMicrophone }
    }

    /// Media requests historically used WebKit's port, which can include a
    /// default port. Preserve both spellings when a choice is edited.
    static func keys(_ kind: Kind, origin: String) -> [String] {
        let original = "capture.\(origin)|\(kind.suffix)"
        guard kind.media, var parts = URLComponents(string: origin),
              let scheme = parts.scheme?.lowercased(), scheme == "https" || scheme == "http" else { return [original] }
        let standardPort = scheme == "https" ? 443 : 80
        guard parts.port == nil || parts.port == standardPort else { return [original] }
        parts.port = nil
        guard let withoutPort = parts.string else { return [original] }
        parts.port = standardPort
        guard let withPort = parts.string else { return [original] }
        return ["capture.\(withoutPort)|\(kind.suffix)", "capture.\(withPort)|\(kind.suffix)"]
    }

    enum Choice: Equatable {
        case ask, allow, refuse, different
        var title: String {
            switch self {
            case .ask: return "Ask"
            case .allow: return "Allow"
            case .refuse: return "Refuse"
            case .different: return "Different"
            }
        }
    }

    static func hasRefusal(_ kind: Kind, origin: String, in settings: UserDefaults = Store.settings) -> Bool {
        keys(kind, origin: origin).contains { (settings.object(forKey: $0) as? Bool) == false }
    }

    /// Default-port spellings name the same origin; a refusal wins conflicts.
    static func mediaDecision(_ kind: Kind, origin: String, in settings: UserDefaults = Store.settings) -> Bool? {
        let answers = keys(kind, origin: origin).compactMap { settings.object(forKey: $0) as? Bool }
        if answers.contains(false) { return false }
        return answers.contains(true) ? true : nil
    }

    static func combinedBlocked(origin: String, in settings: UserDefaults = Store.settings) -> Bool {
        hasRefusal(.camera, origin: origin, in: settings) || hasRefusal(.microphone, origin: origin, in: settings)
    }

    static func combinedAllowed(origin: String, in settings: UserDefaults = Store.settings) -> Bool {
        choice(.camera, origin: origin, in: settings) == .allow &&
        choice(.microphone, origin: origin, in: settings) == .allow
    }

    static func choice(_ kind: Kind, origin: String, in settings: UserDefaults = Store.settings) -> Choice {
        let allKeys = keys(kind, origin: origin)
        let saved = allKeys.compactMap { settings.object(forKey: $0) as? Bool }
        guard !saved.isEmpty else { return .ask }
        if Set(saved).count > 1 { return .different }
        return saved[0] ? .allow : .refuse
    }

    // Invalidate a queued question if the user changes its setting before it
    // can be shown. The stored answer format remains unchanged.
    private static var revisions: [String: UInt] = [:]
    static func revision(for key: String) -> UInt { revisions[key, default: 0] }

    @discardableResult
    static func set(_ value: Bool?, for kind: Kind, origin: String, in settings: UserDefaults = Store.settings) -> Set<String> {
        var changed = Set(keys(kind, origin: origin))
        if kind == .cameraAndMicrophone {
            changed.formUnion(keys(.camera, origin: origin))
            changed.formUnion(keys(.microphone, origin: origin))
        }
        for key in changed {
            if let value { settings.set(value, forKey: key) }
            else { settings.removeObject(forKey: key) }
        }
        var invalidated = changed
        if kind == .camera || kind == .microphone {
            invalidated.formUnion(keys(.cameraAndMicrophone, origin: origin))
        }
        for key in invalidated { revisions[key, default: 0] &+= 1 }
        return invalidated
    }
}
