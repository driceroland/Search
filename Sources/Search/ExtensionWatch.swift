import AppKit
import WebKit

// Tab group and idle events, told as they happen.
//
// WebKit has neither chrome.tabGroups' events nor chrome.idle.onStateChanged,
// so the shim made them up by asking: the groups every 3 s and the idle state
// every 15 s, for as long as an extension listened. Each ask was a native
// call and a wake of the extension's worker, round the clock, whether or
// not anything had changed.
//
// Search knows when a group is made, renamed, folded or emptied, and when the
// Mac goes quiet or locks, so a context that listens opens a native port
// here and Search speaks on it when there is something to say. The groups
// are still told as before — the shim asks for them and works out what
// changed — only now it is asked when they have, not every few seconds.
// Nobody listening, nothing runs: no timer, no observer, no reading.
//
// The shim says hello on a new port until it is answered, as the socket
// does (see ExtensionSocket): WebKit drops what a worker posts in a port's
// first moments, and what Search posts in them is often lost too. So the
// answer to a hello, "listening", is sent every time, and what the shim
// may have missed is sent again with it.

/// One listening context: how to speak to it, and whether it can still hear.
@MainActor
final class ExtensionEar {
    let extensionID: String
    /// A worker's ear goes when the worker does, which WebKit doesn't always say.
    var worker = false
    let say: ([String: Any]) -> Void
    let hears: () -> Bool
    let close: () -> Void
    /// Idle only: how long the Mac must be quiet to be idle for this context,
    /// and the state it was last told (the shim starts from "active").
    var threshold: TimeInterval = 60
    var told = "active"

    init(extensionID: String, say: @escaping ([String: Any]) -> Void, hears: @escaping () -> Bool, close: @escaping () -> Void = {}) {
        self.extensionID = extensionID
        self.say = say
        self.hears = hears
        self.close = close
    }
}

/// Says "changed" to every listening context when the groups an extension is
/// shown are not what they were.
@MainActor
final class GroupWatch {
    /// A group as an extension sees it change: its title and whether it is
    /// folded, which is all the shim tells (see `shape` there).
    struct Shape: Hashable {
        let id: UUID
        let name: String
        let collapsed: Bool
    }

    private let read: () -> Set<Shape>
    private let soon: (@escaping () -> Void) -> Void
    private var ears: [ExtensionEar] = []
    private var last: Set<Shape> = []
    private var settling = false

    init(read: @escaping () -> Set<Shape>, soon: @escaping (@escaping () -> Void) -> Void) {
        self.read = read
        self.soon = soon
    }

    var isListened: Bool { !ears.isEmpty }

    func add(_ ear: ExtensionEar) {
        ears.removeAll { !$0.hears() }
        guard !ears.contains(where: { $0 === ear }) else { return }
        if ears.isEmpty { last = read() }
        ears.append(ear)
    }

    func remove(_ ear: ExtensionEar) {
        ears.removeAll { $0 === ear }
    }

    /// Called wherever a group, or a tab's place in one, may have changed.
    /// Cheap where nobody listens, which is nearly always. Looked at once
    /// the change has been made: the publishers it comes from speak before
    /// it is, and several changes at once (a group closed with its tabs) are
    /// one look.
    func changed() {
        guard !ears.isEmpty, !settling else { return }
        settling = true
        soon { [weak self] in self?.settle() }
    }

    private func settle() {
        settling = false
        ears.removeAll { !$0.hears() }
        guard !ears.isEmpty else { return }
        let now = read()
        guard now != last else { return }
        last = now
        for ear in ears { ear.say(["changed": true]) }
    }
}

/// Tells each listening context when the Mac becomes idle, locked or active
/// again, as chrome.idle does, without anyone asking.
@MainActor
final class IdleWatch {
    struct Reading {
        var locked: Bool
        var quiet: TimeInterval
    }

    private let read: () -> Reading
    private let after: (TimeInterval, @escaping () -> Void) -> () -> Void
    private let signals: (@escaping () -> Void) -> () -> Void
    private var ears: [ExtensionEar] = []
    private var cancelCheck: (() -> Void)?
    private var stopSignals: (() -> Void)?

    /// `after` runs the closure once, later, and gives back a way to cancel
    /// it; `signals` calls it whenever the Mac locks or unlocks, and gives
    /// back a way to stop.
    init(read: @escaping () -> Reading,
         after: @escaping (TimeInterval, @escaping () -> Void) -> () -> Void,
         signals: @escaping (@escaping () -> Void) -> () -> Void) {
        self.read = read
        self.after = after
        self.signals = signals
    }

    /// Whether anything is scheduled or observed: never, with nobody listening.
    var isRunning: Bool { cancelCheck != nil || stopSignals != nil }
    var isListened: Bool { !ears.isEmpty }

    /// The state chrome.idle reports for a reading: locked beats idle.
    nonisolated static func state(_ reading: Reading, threshold: TimeInterval) -> String {
        reading.locked ? "locked" : reading.quiet >= threshold ? "idle" : "active"
    }

    /// How long until the state could be anything else.
    nonisolated static func wait(after state: String, quiet: TimeInterval, threshold: TimeInterval) -> TimeInterval {
        switch state {
        // Idle once the rest of the quiet has gone by, a second over so the
        // look is never early; a key or the pointer starts it over, and the
        // look then finds that out and waits again.
        case "active": return max(threshold - quiet, 0) + 1
        // The Mac says when it unlocks. This is only for a signal that
        // never came.
        case "locked": return 300
        // Nothing says when someone comes back but their first key or
        // movement, so idle is looked at as often as it always was.
        default: return 15
        }
    }

    func add(_ ear: ExtensionEar, threshold: TimeInterval) {
        ear.threshold = threshold
        if !ears.contains(where: { $0 === ear }) { ears.append(ear) }
        if stopSignals == nil { stopSignals = signals { [weak self] in self?.check() } }
        check()
    }

    func remove(_ ear: ExtensionEar) {
        ears.removeAll { $0 === ear }
        if ears.isEmpty { stop() }
    }

    private func stop() {
        cancelCheck?()
        cancelCheck = nil
        stopSignals?()
        stopSignals = nil
    }

    func check() {
        cancelCheck?()
        cancelCheck = nil
        ears.removeAll { !$0.hears() }
        guard !ears.isEmpty else { stop(); return }
        let reading = read()
        var next = TimeInterval.infinity
        for ear in ears {
            let state = Self.state(reading, threshold: ear.threshold)
            if state != ear.told {
                ear.told = state
                ear.say(["state": state])
            }
            next = min(next, Self.wait(after: state, quiet: reading.quiet, threshold: ear.threshold))
        }
        cancelCheck = after(next) { [weak self] in self?.check() }
    }
}

@available(macOS 15.4, *)
@MainActor
enum ExtensionWatch {
    static let groupsPort = ExtensionShims.application + ".groups"
    static let idlePort = ExtensionShims.application + ".idle"

    static let groups = GroupWatch(
        read: { Set(Browsers.all.flatMap(ExtensionShims.listedGroups).map { GroupWatch.Shape(id: $0.id, name: $0.name, collapsed: $0.collapsed) }) },
        soon: { work in DispatchQueue.main.async { MainActor.assumeIsolated { work() } } })

    static let idle = IdleWatch(
        read: { IdleWatch.Reading(locked: screenLocked, quiet: quietSeconds) },
        after: { delay, work in
            let timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { _ in
                MainActor.assumeIsolated { work() }
            }
            // Nothing here is urgent: the system may fire it with other wakes.
            timer.tolerance = min(delay / 4, 5)
            return { timer.invalidate() }
        },
        signals: { work in
            let center = DistributedNotificationCenter.default()
            let tokens = ["com.apple.screenIsLocked", "com.apple.screenIsUnlocked"].map { name in
                center.addObserver(forName: NSNotification.Name(name), object: nil, queue: .main) { _ in
                    MainActor.assumeIsolated { work() }
                }
            }
            return { tokens.forEach { center.removeObserver($0) } }
        })

    static var screenLocked: Bool {
        (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool == true
    }

    /// Seconds since the last key, click or movement.
    static var quietSeconds: TimeInterval {
        guard let any = CGEventType(rawValue: ~0) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: any)
    }

    /// What `chrome.idle.queryState` answers.
    static func idleState(threshold: TimeInterval) -> String {
        IdleWatch.state(IdleWatch.Reading(locked: screenLocked, quiet: quietSeconds), threshold: threshold)
    }

    /// Held from a port's opening until either end lets go.
    private static var open: [ObjectIdentifier: ExtensionEar] = [:]

    /// What is being watched for extensions, for the bench: nothing, with
    /// none listening.
    static var status: [String: Any] {
        ["groups": groups.isListened, "idle": idle.isRunning, "ports": open.count]
    }

    /// A port the shim opened to hear of groups or of idleness. Only to an
    /// extension that asked for the permission, as for the calls the shim
    /// makes: what it is told here is no more than it could ask.
    static func connect(_ port: WKWebExtension.MessagePort, from context: WKWebExtensionContext) throws {
        let id = context.uniqueIdentifier
        let forIdle = port.applicationIdentifier == idlePort
        let permission = forIdle ? "idle" : "tabGroups"
        guard ExtensionShims.allowed(id, context: context).contains(permission) else {
            throw ExtensionShims.Unsupported(what: "The extension never asked for \u{201C}\(permission)\u{201D}")
        }
        sweep()
        let ear = ExtensionEar(
            extensionID: id,
            say: { message in if !port.isDisconnected { port.sendMessage(message, completionHandler: nil) } },
            hears: { !port.isDisconnected },
            close: {
                port.messageHandler = nil
                port.disconnectHandler = nil
                if !port.isDisconnected { port.disconnect() }
            })
        open[ObjectIdentifier(ear)] = ear
        port.messageHandler = { message, _ in
            MainActor.assumeIsolated {
                guard let hello = message as? [String: Any], hello["listen"] as? Bool == true else { return }
                ear.worker = hello["worker"] as? Bool == true
                ear.say(["listening": true])
                if forIdle {
                    // What it has missed is said again: it starts from active.
                    ear.told = "active"
                    let every = (hello["every"] as? NSNumber)?.doubleValue ?? 60
                    idle.add(ear, threshold: every.isFinite ? max(15, every) : 60)
                } else {
                    groups.add(ear)
                }
            }
        }
        port.disconnectHandler = { _ in
            MainActor.assumeIsolated { release(ear) }
        }
        ear.say(["ready": true])
    }

    /// Its port's handlers hold the ear and the ear holds the port: both
    /// are let go together.
    private static func release(_ ear: ExtensionEar) {
        groups.remove(ear)
        idle.remove(ear)
        open[ObjectIdentifier(ear)] = nil
        ear.close()
    }

    /// Ports WebKit has let go without a word.
    private static func sweep() {
        for ear in open.values where !ear.hears() { release(ear) }
    }

    /// A worker's ports go with it, and WebKit doesn't always say so (see
    /// ExtensionNative.stopWorkerHosts): as an extension's worker starts
    /// again, the ears its last worker opened are let go.
    static func workerGone(of extensionID: String) {
        for ear in open.values where ear.worker && ear.extensionID == extensionID { release(ear) }
    }
}
