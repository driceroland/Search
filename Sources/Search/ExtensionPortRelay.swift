import Foundation

/// What an app on the Mac says to an extension, on its way to the port.
///
/// A port's first moments are where WebKit goes wrong: what a worker posts
/// on a port it has just opened comes back to its own listeners, and what
/// arrives on one in a process that has only just started can reach a
/// listener that isn't there. A 1Password user's 37 WebContent crash
/// reports all end in WebKit's dispatchPortMessageEvent, on a null or freed
/// listener, a fraction of a second after the extension's process started,
/// as 1Password's helper answered (idea 797). So what the app says is held
/// until the extension has said something on the port itself — the hello an
/// extension sends, or the shim's "here?" — which shows its side is there
/// and listening, or until a grace has passed; then it goes, in order.
/// Once the port has gone, nothing more goes: what the app still says is
/// dropped, never handed to WebKit for a page or worker that isn't there.
@MainActor
final class PortRelay {
    /// How long what an app says waits for the extension to speak first.
    static let grace: TimeInterval = 1
    /// The most held at once; more and it all goes (an app that says that
    /// much unasked is better heard late than dropped).
    static let cap = 4096

    private var held: [Any]? = []
    private(set) var closed = false
    private let send: (Any) -> Void
    private let gone: () -> Bool

    /// `send` posts to the port; `gone` says whether it has been let go.
    init(send: @escaping (Any) -> Void, gone: @escaping () -> Bool) {
        self.send = send
        self.gone = gone
    }

    /// How many messages are waiting (for the bench and the tests).
    var holding: Int { held?.count ?? 0 }
    /// Whether messages go straight through.
    var isOpen: Bool { held == nil && !closed }

    /// A message from the app.
    func fromApp(_ message: Any) {
        guard !closed else { return }
        if gone() { close(); return }
        if held != nil {
            held!.append(message)
            if held!.count >= Self.cap { open() }
            return
        }
        send(message)
    }

    /// The extension said something on the port: it is there.
    func heard() { open() }

    /// Whatever waits goes, in order, and from now on straight through.
    func open() {
        guard !closed, let list = held else { return }
        held = nil
        for message in list {
            if gone() { close(); return }
            send(message)
        }
    }

    /// The port has gone: nothing more is sent.
    func close() {
        closed = true
        held = nil
    }
}
