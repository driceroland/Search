import SwiftUI

// What the window shows of a coding agent (AgentControl). When one
// connects, the question, rising from the foot of the window with the
// page's own questions, in the window it asked in only. Never anything over
// the page after that: while it is allowed, the tab it is working in wears
// a dot on its icon's corner (AgentMark), moving with it from tab to tab and
// gone once it is idle; Stop is on that row under the pointer, on a quiet
// line at the foot of the column — or at the far end of the strip when the
// tabs are across the top — and in File › Stop Agent, all for as long as it
// is connected, and gone with it.
//
// Neither the question nor its buttons take the keys: Return never allows,
// and nothing an agent sends reaches these buttons, which only a click of
// yours presses: a press through Accessibility, with no mouse event in the
// window behind it, is ignored (AgentRules.isClick). Mouse events made up by
// another process trusted with Accessibility and input are out of scope.

struct AgentBar: View {
    @ObservedObject var browser: Browser
    @ObservedObject private var agents = AgentControl.shared

    var body: some View {
        Group {
            // Which window it asked in is the session's to say, once it has
            // said hello: watched there, not here.
            if let session = agents.session {
                AgentSessionBar(session: session, browser: browser)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(Motion.settle, value: agents.session?.id)
    }
}

private struct AgentSessionBar: View {
    @ObservedObject var session: AgentSession
    let browser: Browser

    var body: some View {
        if session.browser === browser, session.consent.state == .asking {
            AgentQuestion(session: session)
        }
    }
}

/// Connected, in the chrome: a quiet line at the foot of the column (`.row`),
/// a mark there when the column is icons only (`.icon`), or at the far end
/// of the strip (`.door`). Each with Stop.
struct AgentStatus: View {
    enum Style { case row, icon, door }
    @ObservedObject var browser: Browser
    let style: Style
    @ObservedObject private var agents = AgentControl.shared

    var body: some View {
        if let session = agents.session, session.browser === browser {
            AgentStatusFace(session: session, style: style)
        }
    }
}

private struct AgentStatusFace: View {
    @ObservedObject var session: AgentSession
    let style: AgentStatus.Style

    var body: some View {
        if session.consent.state == .allowed {
            switch style {
            case .icon:
                Button { AgentControl.shared.stopSession() } label: {
                    Image(systemName: "stop.circle")
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.muted)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                        .background(ClickSpot { AgentControl.shared.stopButton = $0 })
                }
                .buttonStyle(.plain)
                .help("\(AgentWords.short(session)). Click to stop it.")
            case .row, .door:
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(session.justAdmitted ? AgentWords.admitted(session)
                             : style == .door ? AgentWords.short(session) : AgentWords.line(session))
                            .font(.system(size: 11, weight: session.justAdmitted ? .medium : .regular))
                            .foregroundStyle(session.justAdmitted ? Palette.ink : Palette.muted)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Text("·").font(.system(size: 11)).foregroundStyle(Palette.muted)
                        AgentStop()
                        if style == .row { Spacer(minLength: 0) }
                    }
                    // Let in without asking: always said, under it.
                    if session.auto, style == .row {
                        Text("Allowed automatically")
                            .font(.system(size: 10))
                            .foregroundStyle(Palette.muted.opacity(0.8))
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, style == .row ? 10 : 4)
                .help(AgentWords.short(session) + ". Stop disconnects it; its tabs stay.")
                .fixedSize(horizontal: style == .door, vertical: true)
            }
        }
    }
}

private struct AgentStop: View {
    @State private var hovering = false
    var body: some View {
        Button { AgentControl.shared.stopSession() } label: {
            Text("Stop")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(hovering ? Palette.ink : Palette.ink.opacity(0.75))
                .contentShape(Rectangle())
                .background(ClickSpot { AgentControl.shared.stopButton = $0 })
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Disconnect it. Its tabs stay where they are.")
    }
}

/// On the icon's corner of an agent's tab, the row's layout never changing
/// for it: while the agent works there, a small dot in the accent colour;
/// otherwise, for as long as the tab is open, a fainter hollow ring, so a
/// tab an agent opened is always told from yours. Each ringed with the row's
/// ground so it reads on any icon.
struct AgentMark: View {
    @ObservedObject var tab: Tab

    var body: some View {
        if tab.agentWorking {
            Circle()
                .fill(Color.accentColor)
                .frame(width: 6, height: 6)
                .padding(1.5)
                .background(Circle().fill(Palette.ground))
                .offset(x: 3, y: 3)
                .allowsHitTesting(false)
                .help("A coding agent is working in this tab")
                .transition(.opacity)
        } else if tab.agent {
            Circle()
                .strokeBorder(Palette.muted, lineWidth: 1)
                .frame(width: 5.5, height: 5.5)
                .padding(1.5)
                .background(Circle().fill(Palette.ground))
                .offset(x: 3, y: 3)
                .allowsHitTesting(false)
                .help("Opened by a coding agent")
        }
    }
}

/// Stop, on the row of the tab an agent is working in, under the pointer.
struct AgentRowStop: View {
    var body: some View {
        Button { AgentControl.shared.stopSession() } label: {
            Text("Stop")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.ink)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Palette.ground, in: Capsule())
                .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Stop the coding agent. Its tabs stay where they are.")
    }
}

/// File › Stop Agent: there while one is connected.
struct StopAgentMenuItem: View {
    @ObservedObject private var agents = AgentControl.shared

    var body: some View {
        Button(agents.shownIn == nil ? "Stop Agent" : "Stop \(agents.session?.client ?? "Agent")") {
            AgentControl.shared.stopSession()
        }
        .shortcut("file.stopAgent")
        .disabled(agents.shownIn == nil)
    }
}

/// What the line says.
enum AgentWords {
    @MainActor
    static func line(_ session: AgentSession) -> String {
        session.busy ? "\(session.client) is using Search" : "\(session.client), idle"
    }

    /// Said for a few seconds once let in without asking.
    @MainActor
    static func admitted(_ session: AgentSession) -> String {
        "\(session.client) let in automatically"
    }

    /// In the strip, where there is room for one short line.
    @MainActor
    static func short(_ session: AgentSession) -> String {
        session.auto ? "\(session.client) · Allowed automatically" : line(session)
    }
}

/// "Claude Code wants to use Search", Allow or Don't Allow.
private struct AgentQuestion: View {
    @ObservedObject var session: AgentSession

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "cursorarrow.rays")
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.muted)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 4) {
                    Text("“\(session.client)” wants to use Search")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Palette.ink)
                    Text(detail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            // Ticked only by a fresh click on it, as Allow is pressed.
            Toggle("Let it see my open tabs", isOn: Binding(
                get: { session.wantsTabs },
                set: { _ in AgentControl.shared.toggleTabs(event: NSApp.currentEvent) }))
                .toggleStyle(.checkbox)
                .background(ClickSpot { AgentControl.shared.tabsBox = $0 })
                .font(.system(size: 12))
                .foregroundStyle(Palette.ink)
                .padding(.leading, 23)
            // Offered only for a program its signature names (AgentTrust);
            // otherwise, why not.
            if let why = session.noAlways {
                Text("Can't be remembered: \(why).")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 23)
            } else {
                Toggle("Always allow \(session.client)", isOn: Binding(
                    get: { session.wantsAlways },
                    set: { _ in AgentControl.shared.toggleAlways(event: NSApp.currentEvent) }))
                    .toggleStyle(.checkbox)
                    .background(ClickSpot { AgentControl.shared.alwaysBox = $0 })
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.ink)
                    .padding(.leading, 23)
                    .help(alwaysHelp)
            }
            HStack(spacing: 12) {
                Spacer(minLength: 8)
                Button { AgentControl.shared.answer(allow: false, event: NSApp.currentEvent) } label: {
                    Text("Don't Allow")
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                        .background(ClickSpot { AgentControl.shared.refuseButton = $0 })
                }
                Button { AgentControl.shared.answer(allow: true, event: NSApp.currentEvent) } label: {
                    Text("Allow")
                        .foregroundStyle(Palette.ground)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Palette.ink, in: Capsule())
                        .background(ClickSpot { AgentControl.shared.allowButton = $0 })
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(Palette.ink)
            .buttonStyle(.plain)
        }
        .frame(maxWidth: 420, alignment: .leading)
        .padding(16)
        .background(Palette.ground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.12), radius: 20, y: 6)
        .padding(.horizontal, 16)
    }

    private var alwaysHelp: String {
        guard let launcher = session.launcher else { return "" }
        return "Next time, if it is started by \(launcher.name), signed by \(launcher.who), and calls itself “\(session.client)”, "
            + "it is let in without asking, for 30 days at most and 7 after it was last used, seeing only its own tabs. "
            + "Stop shows as ever, and stopping it asks again next time. Forget it in Settings › About › Developer."
    }

    /// The name is the program's own word for itself; this is macOS's.
    private var detail: String {
        let from = session.program.isEmpty ? "" : "From \(session.program) on this Mac. "
        return from + "It works in tabs of its own while you watch, until you press Stop. "
            + "It never sees passwords, card numbers, private tabs or Settings."
    }
}

/// An AppKit view the size of the control it sits behind, so a click can be
/// checked to have landed on that control (AgentRules.isClick). It takes no
/// clicks itself.
private struct ClickSpot: NSViewRepresentable {
    let made: (NSView) -> Void

    final class Spot: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeNSView(context: Context) -> NSView {
        let view = Spot()
        made(view)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}
}
