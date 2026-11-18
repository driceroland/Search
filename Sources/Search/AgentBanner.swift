import SwiftUI

// What the window shows of a coding agent (AgentControl): the question when
// one connects, and while it is allowed, a small pill saying so with Stop.
// Both rise from the foot of the window with the page's own questions, in
// the window it asked in only. Neither takes the keys: Return never allows,
// and nothing an agent sends reaches these buttons, which only a click of
// yours presses: a press through Accessibility, with no mouse event in the
// window behind it, is ignored (AgentRules.isClick). Mouse events made up by
// another process trusted with Accessibility and input are out of scope.

struct AgentBar: View {
    @ObservedObject var browser: Browser
    @ObservedObject private var agents = AgentControl.shared

    var body: some View {
        Group {
            if let session = agents.session, session.browser === browser {
                AgentSessionBar(session: session)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(Motion.settle, value: agents.session?.id)
    }
}

private struct AgentSessionBar: View {
    @ObservedObject var session: AgentSession

    var body: some View {
        switch session.consent.state {
        case .asking: AgentQuestion(session: session)
        case .allowed: AgentPill(session: session)
        default: EmptyView()
        }
    }
}

/// "Claude Code wants to use Search", Allow or Don't Allow.
private struct AgentQuestion: View {
    @ObservedObject var session: AgentSession
    @State private var seesTabs = false

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
            Toggle("Let it see my open tabs", isOn: $seesTabs)
                .toggleStyle(.checkbox)
                .font(.system(size: 12))
                .foregroundStyle(Palette.ink)
                .padding(.leading, 23)
            HStack(spacing: 12) {
                Spacer(minLength: 8)
                Button { AgentControl.shared.answer(allow: false, seesTabs: false, event: NSApp.currentEvent) } label: {
                    Text("Don't Allow")
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                }
                Button { AgentControl.shared.answer(allow: true, seesTabs: seesTabs, event: NSApp.currentEvent) } label: {
                    Text("Allow")
                        .foregroundStyle(Palette.ground)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Palette.ink, in: Capsule())
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

    /// The name is the program's own word for itself; this is macOS's.
    private var detail: String {
        let from = session.program.isEmpty ? "" : "From \(session.program) on this Mac. "
        return from + "It works in tabs of its own while you watch, until you press Stop. "
            + "It never sees passwords, card numbers, private tabs or Settings."
    }
}

/// "● Claude Code is using Search   Stop".
private struct AgentPill: View {
    @ObservedObject var session: AgentSession

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Color.accentColor)
                .frame(width: 7, height: 7)
            Text("\(session.client) is using Search")
                .font(.system(size: 12))
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
            Button { AgentControl.shared.stopSession() } label: {
                Text("Stop")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.ink)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help("Disconnect it. Its tabs stay where they are.")
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .background(Palette.ground, in: Capsule())
        .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.10), radius: 14, y: 4)
    }
}
