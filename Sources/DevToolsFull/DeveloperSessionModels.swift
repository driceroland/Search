import Foundation

/// A model a DevTools panel or drawer tool keeps per session
/// (DeveloperSessionModels), told when that session closes.
@MainActor
protocol DeveloperSessionModel: AnyObject {
    /// The session disconnected: stop listening, take scripts and
    /// message handlers out of the page, cancel what is running.
    func sessionClosed()
}

/// One home for the models panels and tools make per session on first use
/// (`model(for:)`, `of(_:)`), in place of a static table in each. A model
/// lives as long as its session is open: DeveloperToolsSession.disconnect
/// lets go of every one, telling those that are DeveloperSessionModels, so
/// none outlives a closed DevTools waiting for the next session to prune it.
@MainActor
enum DeveloperSessionModels {
    private struct Key: Hashable {
        let session: ObjectIdentifier
        let model: ObjectIdentifier
    }

    private struct Entry {
        weak var session: DeveloperToolsSession?
        let model: AnyObject
    }

    private static var entries: [Key: Entry] = [:]

    /// The session's model of this type, made with `make` the first time.
    static func model<Model: AnyObject>(for session: DeveloperToolsSession,
                                        make: (DeveloperToolsSession) -> Model) -> Model {
        let key = Key(session: ObjectIdentifier(session), model: ObjectIdentifier(Model.self))
        if let entry = entries[key], entry.session === session, let model = entry.model as? Model { return model }
        pruneGoneSessions()
        let model = make(session)
        entries[key] = Entry(session: session, model: model)
        return model
    }

    /// The session's model of this type if one was made; never makes one.
    static func existing<Model: AnyObject>(_ type: Model.Type, for session: DeveloperToolsSession) -> Model? {
        let key = Key(session: ObjectIdentifier(session), model: ObjectIdentifier(type))
        guard let entry = entries[key], entry.session === session else { return nil }
        return entry.model as? Model
    }

    /// The session closed: its models are let go, each told first.
    static func closed(_ session: DeveloperToolsSession) {
        let id = ObjectIdentifier(session)
        let closing = entries.filter { $0.key.session == id }
        guard !closing.isEmpty else { return }
        for key in closing.keys { entries[key] = nil }
        for entry in closing.values { (entry.model as? any DeveloperSessionModel)?.sessionClosed() }
    }

    /// Models whose session went away without closing (tests, mostly).
    private static func pruneGoneSessions() {
        let gone = entries.filter { $0.value.session == nil }
        guard !gone.isEmpty else { return }
        for key in gone.keys { entries[key] = nil }
        for entry in gone.values { (entry.model as? any DeveloperSessionModel)?.sessionClosed() }
    }
}
