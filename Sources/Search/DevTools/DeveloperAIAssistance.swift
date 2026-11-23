import AppKit
import SwiftUI
#if canImport(FoundationModels)
import FoundationModels
#endif

// Chrome DevTools' AI assistance, answered by Apple's on-device model
// (FoundationModels) rather than a server: a chat in the drawer about the
// selected element, a network request or a Console message, opened from
// Elements' and Network's "Ask AI" and the Console's "Understand this error".
//
// The model only reads the context DeveloperAIContextText writes for it.
// Chrome's agent can also run JavaScript in the inspected page; that is
// deliberately out of scope here. The session is made without tools, and
// nothing it answers is evaluated, so it can't change or probe the page.

/// Whether AI assistance can answer, and if not, why, in Chrome's manner.
enum DeveloperAIAvailability: Equatable {
    case available
    /// Settings › Preferences › AI assistance is off.
    case turnedOff
    case appleIntelligenceOff
    case deviceNotEligible
    case modelNotReady
    /// Before macOS 26, or built without FoundationModels.
    case unsupportedSystem
    case unavailable

    var message: String? {
        switch self {
        case .available: nil
        case .turnedOff: "AI assistance is turned off. You can turn it on in Settings › Preferences."
        case .appleIntelligenceOff: "To use AI assistance, turn on Apple Intelligence in System Settings › Apple Intelligence & Siri."
        case .deviceNotEligible: "AI assistance isn’t available on this device. It needs a Mac that supports Apple Intelligence."
        case .modelNotReady: "The on-device model isn’t ready yet. It may still be downloading; try again in a few minutes."
        case .unsupportedSystem: "AI assistance needs macOS 26 or later."
        case .unavailable: "AI assistance isn’t available right now."
        }
    }

    /// The model's state now; `enabled` is the setting.
    @MainActor static func current(enabled: Bool) -> Self {
        guard enabled else { return .turnedOff }
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return .available
            case .unavailable(.appleIntelligenceNotEnabled): return .appleIntelligenceOff
            case .unavailable(.deviceNotEligible): return .deviceNotEligible
            case .unavailable(.modelNotReady): return .modelNotReady
            case .unavailable: return .unavailable
            }
        }
        #endif
        return .unsupportedSystem
    }
}

#if canImport(FoundationModels)
/// One chat's model session. Made with instructions and no tools: it can
/// only read what it is sent.
@available(macOS 26.0, *)
@MainActor
private final class DeveloperAIEngine {
    private var session = DeveloperAIEngine.make()

    private static func make() -> LanguageModelSession {
        LanguageModelSession(instructions: DeveloperAIContextText.instructions)
    }

    /// Forgets the conversation, for a chat that outgrew the context window.
    func reset() { session = Self.make() }

    /// Streams the answer, each snapshot the whole answer so far.
    func stream(_ prompt: String, update: (String) -> Void) async throws {
        let stream = session.streamResponse(to: prompt)
        for try await snapshot in stream {
            try Task.checkCancellation()
            update(snapshot.content)
        }
    }

    static func overflowed(_ error: Error) -> Bool {
        if let error = error as? LanguageModelSession.GenerationError, case .exceededContextWindowSize = error { return true }
        return false
    }

    static func describe(_ error: Error) -> String {
        if let error = error as? LanguageModelSession.GenerationError {
            switch error {
            case .guardrailViolation:
                return "The on-device model can’t answer this. Try rephrasing your question."
            case .assetsUnavailable:
                return DeveloperAIAvailability.modelNotReady.message ?? error.localizedDescription
            case .unsupportedLanguageOrLocale:
                return "The on-device model doesn’t support this language yet."
            case .exceededContextWindowSize:
                return "This conversation is too long for the on-device model. Start a new chat to continue."
            default:
                break
            }
        }
        return error.localizedDescription
    }
}
#endif

/// One session's chat: what it's about, what was said, and the answer
/// being streamed.
@MainActor
final class DeveloperAIAssistance: ObservableObject {
    /// Settings › Preferences › AI assistance; on unless turned off.
    static let enabledKey = "developerTools.aiAssistance.enabled"
    static var enabled: Bool { Store.settings.object(forKey: enabledKey) as? Bool ?? true }

    struct Message: Identifiable, Equatable {
        let id = UUID()
        let fromUser: Bool
        var text: String
        var failed = false
    }

    @Published private(set) var subject: DeveloperAISubject?
    @Published private(set) var messages: [Message] = []
    @Published private(set) var responding = false
    @Published var draft = ""

    private weak var session: DeveloperToolsSession?
    /// The FoundationModels engine, typed only where it is available.
    private var engine: AnyObject?
    private var task: Task<Void, Never>?
    /// What the model was last told about in this chat, so the context goes
    /// with the next question only when it changed.
    private var toldSubject: DeveloperAISubject?
    /// Characters the model's session has read and written this chat.
    private var spent = 0

    init(session: DeveloperToolsSession) {
        self.session = session
    }

    // MARK: Entry points

    /// Elements › a node's context menu › Ask AI.
    func askAboutElement(_ id: Int) {
        guard let session else { return }
        session.selectNode(id)
        show(.element(node: id, label: elementLabel(id)))
    }

    /// Network › a request's context menu › Ask AI.
    func askAboutRequest(_ request: DeveloperToolsSession.Request) {
        show(.request(id: request.id, label: request.name))
    }

    /// Performance › an entry's context menu › Ask AI. `key` names the
    /// recording and the entry, so asking again keeps the chat's context.
    func askAboutTraceEvent(_ event: DeveloperPerformanceEvent, in profile: DeveloperPerformanceProfile, key: String) {
        let context = DeveloperAIContextText.traceEvent(event, in: profile)
        show(.traceEvent(id: key + ":" + String(event.id), label: event.title, context: context))
    }

    /// Performance › an insight's card › Ask AI.
    func askAboutInsight(_ insight: DeveloperPerformanceInsight) {
        show(.insight(id: insight.id, label: insight.title, context: DeveloperAIContextText.insight(insight)))
    }

    /// Sources › the editor's context menu (or status bar) › Ask AI, about
    /// the file open as it reads now.
    func askAboutFile(url: String, language: SourceLanguage, text: String, line: Int?, selection: String?) {
        let context = DeveloperAIContextText.file(url: url, language: DeveloperAIContextText.languageName(language),
                                                  text: text, line: line, selection: selection)
        show(.file(url: url, label: SourceTree.fileName(url), context: context))
    }

    /// Console › Understand this error (or warning): a new chat that asks
    /// at once, as Chrome's Console insight does.
    func understand(_ line: DeveloperToolsSession.ConsoleLine) {
        newChat()
        let subject = DeveloperAISubject.console(line)
        show(subject)
        ask(subject.examplePrompts[0])
    }

    /// Shows AI assistance in the drawer, about `subject`.
    func show(_ subject: DeveloperAISubject) {
        if !subject.same(as: self.subject) { self.subject = subject }
        DeveloperToolsShell.shared.showDrawer(.tool(.aiAssistance))
    }

    // MARK: Context

    private func elementLabel(_ id: Int) -> String {
        guard let node = session?.nodes[id] else { return "element" }
        return DeveloperAIContextText.elementLabel(name: node.name, attributes: node.attributes)
    }

    /// With nothing chosen yet, the element selected in Elements, as
    /// Chrome's panel starts from it.
    func adoptSelection() {
        guard subject == nil, messages.isEmpty, let id = session?.selectedNode,
              session?.nodes[id]?.type == 1 else { return }
        subject = .element(node: id, label: elementLabel(id))
    }

    /// The chip follows the selection in Elements while it shows an element.
    func followSelection() {
        guard !responding, case .element = subject, let id = session?.selectedNode,
              session?.nodes[id]?.type == 1 else { return }
        let next = DeveloperAISubject.element(node: id, label: elementLabel(id))
        if !next.same(as: subject) { subject = next }
    }

    func removeSubject() { subject = nil }

    /// The context's text, read from the session as it is now.
    private func gather(_ subject: DeveloperAISubject) async -> String {
        switch subject {
        case .element(let node, let label):
            guard let session else { return "The selected element: " + label }
            let html = (try? await session.outerHTML(of: node)) ?? ""
            // Styles holds the selected element's style; the chip names it
            // unless the selection moved while answering.
            let current = session.selectedNode == node
            return DeveloperAIContextText.element(label: label, outerHTML: html,
                                                  computed: current ? session.styles : [],
                                                  rules: current ? session.matchedStyles : [])
        case .request(let id, let label):
            guard let session, let request = session.requests.first(where: { $0.id == id }) else {
                return "The selected network request: " + label
            }
            let details = await session.requestDetails(id)
            return DeveloperAIContextText.request(request, details: details)
        case .console(let line):
            return DeveloperAIContextText.console(line)
        case .traceEvent(_, _, let context), .insight(_, _, let context), .file(_, _, let context):
            return context
        }
    }

    // MARK: Chat

    /// The new-chat button: the conversation forgotten, the chip kept.
    func newChat() {
        task?.cancel()
        task = nil
        responding = false
        messages = []
        engine = nil
        toldSubject = nil
        spent = 0
    }

    func stop() {
        task?.cancel()
        task = nil
        responding = false
        if let last = messages.indices.last, !messages[last].fromUser, messages[last].text.isEmpty {
            messages[last].text = "Response stopped."
            messages[last].failed = true
        }
    }

    func send() {
        let question = draft
        draft = ""
        ask(question)
    }

    func ask(_ question: String) {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !responding else { return }
        messages.append(Message(fromUser: true, text: question))
        let answer = Message(fromUser: false, text: "")
        messages.append(answer)
        let availability = DeveloperAIAvailability.current(enabled: Self.enabled)
        guard availability == .available else {
            fail(answer.id, availability.message ?? "AI assistance isn’t available right now.")
            return
        }
        responding = true
        let subject = subject
        task = Task { [weak self] in
            await self?.answer(question, about: subject, into: answer.id)
            guard let self, !Task.isCancelled else { return }
            self.responding = false
            self.task = nil
        }
    }

    private func answer(_ question: String, about subject: DeveloperAISubject?, into id: UUID) async {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let engine = (self.engine as? DeveloperAIEngine) ?? DeveloperAIEngine()
            self.engine = engine
            var retried = false
            var includeContext = subject.map { !$0.same(as: toldSubject) } ?? false
            while true {
                var context: String?
                if includeContext, let subject { context = await gather(subject) }
                guard !Task.isCancelled else { return }
                let prompt = DeveloperAIContextText.prompt(question: question, context: context)
                // The conversation so far plus this turn would outgrow the
                // window: start the model afresh, told the context again.
                if DeveloperAIContextText.needsFreshSession(spent: spent, next: prompt.count), spent > 0 {
                    engine.reset()
                    spent = 0
                    toldSubject = nil
                    if !includeContext, subject != nil { includeContext = true; continue }
                }
                do {
                    var answered = 0
                    try await engine.stream(prompt) { [weak self] text in
                        answered = text.count
                        self?.update(id, text)
                    }
                    spent += prompt.count + answered
                    toldSubject = subject
                    return
                } catch is CancellationError {
                    return
                } catch {
                    guard !Task.isCancelled else { return }
                    // Too long for the window: a fresh session, told the
                    // context again, asked once more, as Chrome starts over.
                    if DeveloperAIEngine.overflowed(error), !retried {
                        retried = true
                        engine.reset()
                        spent = 0
                        toldSubject = nil
                        includeContext = subject != nil
                        continue
                    }
                    fail(id, DeveloperAIEngine.describe(error))
                    return
                }
            }
        }
        #endif
        fail(id, DeveloperAIAvailability.unsupportedSystem.message ?? "")
    }

    private func update(_ id: UUID, _ text: String) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].text = text
    }

    private func fail(_ id: UUID, _ text: String) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].text = text
        messages[index].failed = true
    }
}

extension DeveloperDrawerTool {
    /// The drawer tools More tools and the command menu offer: AI
    /// assistance only while it is turned on.
    @MainActor static var offered: [DeveloperDrawerTool] {
        allCases.filter { $0 != .aiAssistance || DeveloperAIAssistance.enabled }
    }
}

// MARK: - View

/// The AI assistance drawer tool: a toolbar with New chat, the
/// conversation, and the prompt under the context chip.
struct DeveloperAIAssistanceView: View {
    @ObservedObject var session: DeveloperToolsSession
    @ObservedObject var assistance: DeveloperAIAssistance
    @ObservedObject private var shell = DeveloperToolsShell.shared
    @AppStorage(DeveloperAIAssistance.enabledKey, store: Store.settings) private var enabled = true
    /// Bumped by Try again, to read the model's availability afresh.
    @State private var recheck = 0
    @FocusState private var promptFocused: Bool

    var body: some View {
        let availability = DeveloperAIAvailability.current(enabled: enabled)
        VStack(spacing: 0) {
            toolbar
            Divider()
            if let reason = availability.message {
                unavailable(reason, availability)
            } else {
                conversation
                Divider()
                composer
            }
        }
        .id(recheck)
        .background(DeveloperToolsStyle.surface)
        .onAppear { assistance.adoptSelection() }
        .onChange(of: session.selectedNode) { _, _ in assistance.followSelection() }
    }

    private var toolbar: some View {
        HStack(spacing: DeveloperToolsStyle.controlSpacing) {
            DeveloperPanelIcon(symbol: "square.and.pencil", title: "New chat") { assistance.newChat() }
                .disabled(assistance.messages.isEmpty)
            Spacer(minLength: 0)
            DeveloperPanelIcon(symbol: "gearshape", title: "Settings") {
                shell.settingsSection = .preferences
                shell.settingsShown = true
            }
        }
        .padding(.horizontal, DeveloperToolsStyle.gutter)
        .frame(height: DeveloperToolsStyle.toolbarHeight)
        .background(DeveloperToolsStyle.chrome)
    }

    private func unavailable(_ reason: String, _ availability: DeveloperAIAvailability) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "sparkles").font(.system(size: 20)).foregroundStyle(.secondary)
            Text(reason)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 360)
            switch availability {
            case .turnedOff:
                Button("Open settings") {
                    shell.settingsSection = .preferences
                    shell.settingsShown = true
                }
                .buttonStyle(PillStyle())
            case .modelNotReady:
                Button("Try again") { recheck += 1 }.buttonStyle(PillStyle())
            default:
                EmptyView()
            }
        }
        .padding(DeveloperToolsStyle.gutter * 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Conversation

    private var conversation: some View {
        ScrollViewReader { reader in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if assistance.messages.isEmpty {
                        welcome
                    } else {
                        ForEach(assistance.messages) { message in
                            DeveloperAIMessageView(message: message,
                                                   streaming: assistance.responding && message.id == assistance.messages.last?.id)
                                .id(message.id)
                        }
                    }
                }
                .padding(DeveloperToolsStyle.gutter + 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: assistance.messages.last?.text) { _, _ in
                if let last = assistance.messages.last?.id { reader.scrollTo(last, anchor: .bottom) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("AI assistance", systemImage: "sparkles").fontWeight(.semibold)
            Text(assistance.subject == nil
                 ? "Select an element in Elements, a request in Network, a message in the Console, an entry or insight in Performance, or a file in Sources, then ask about it."
                 : "Ask a question, or start with one of these:")
                .foregroundStyle(.secondary)
            let prompts = assistance.subject?.examplePrompts ?? ["What can you help me with?"]
            VStack(alignment: .leading, spacing: DeveloperToolsStyle.stackSpacing) {
                ForEach(prompts, id: \.self) { prompt in
                    Button(prompt) { assistance.ask(prompt) }
                        .buttonStyle(PillStyle())
                }
            }
        }
    }

    // MARK: Prompt

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let subject = assistance.subject { chip(subject) }
            HStack(alignment: .bottom, spacing: DeveloperToolsStyle.controlSpacing) {
                TextField(assistance.subject?.placeholder ?? "Ask a question", text: $assistance.draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...5)
                    .focused($promptFocused)
                    .onSubmit { assistance.send() }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .frame(minHeight: DeveloperToolsStyle.controlHeight)
                    .background(DeveloperToolsStyle.raised, in: RoundedRectangle(cornerRadius: DeveloperToolsStyle.controlRadius))
                    .accessibilityLabel("Ask a question")
                if assistance.responding {
                    DeveloperPanelIcon(symbol: "stop.fill", title: "Stop response") { assistance.stop() }
                } else {
                    DeveloperPanelIcon(symbol: "arrow.up", title: "Send") { assistance.send() }
                        .disabled(assistance.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            Text("Answers come from Apple’s on-device model and may be inaccurate. Nothing is sent off this Mac.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .padding(DeveloperToolsStyle.gutter)
        .onAppear { promptFocused = true }
    }

    /// The context chip: what the chat is about, and × to ask without it.
    private func chip(_ subject: DeveloperAISubject) -> some View {
        HStack(spacing: 4) {
            Image(systemName: subject.icon).font(.system(size: 9)).foregroundStyle(.secondary)
            Text(subject.label)
                .font(DeveloperToolsStyle.code)
                .lineLimit(1)
                .truncationMode(.middle)
            Button { assistance.removeSubject() } label: {
                Image(systemName: "xmark").font(.system(size: 8, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Remove context")
            .disabled(assistance.responding)
        }
        .padding(.horizontal, 6)
        .frame(height: DeveloperToolsStyle.controlHeight)
        .background(DeveloperToolsStyle.selected, in: RoundedRectangle(cornerRadius: DeveloperToolsStyle.controlRadius))
        .help(subject.label)
    }
}

/// One turn of the chat: who said it, and the text, the answer's Markdown
/// rendered as it streams.
private struct DeveloperAIMessageView: View {
    let message: DeveloperAIAssistance.Message
    let streaming: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(message.fromUser ? "You" : "AI assistance")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.secondary)
            if !message.fromUser && message.text.isEmpty && streaming {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Thinking…").foregroundStyle(.secondary)
                }
            } else {
                Text(rendered)
                    .textSelection(.enabled)
                    .foregroundStyle(message.failed ? Color.secondary : Palette.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(message.fromUser ? 6 : 0)
        .background(message.fromUser ? DeveloperToolsStyle.raised : .clear,
                    in: RoundedRectangle(cornerRadius: DeveloperToolsStyle.controlRadius))
    }

    private var rendered: AttributedString {
        guard !message.fromUser, !message.failed else { return AttributedString(message.text) }
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: message.text, options: options)) ?? AttributedString(message.text)
    }
}
