import AppKit
import SwiftUI

/// A console message whose arguments a page's custom formatter drew: the
/// formatted objects show their headers, the rest of the message as usual.
/// Until a formatter answers (or when none takes an argument) `fallback`,
/// the usual message, shows.
struct ConsoleCustomFormattedMessage<Fallback: View>: View {
    @ObservedObject var session: DeveloperToolsSession
    @ObservedObject var store: DeveloperConsoleStore
    let segments: [ConsoleSegment]
    let targetID: String?
    let key: String
    @ViewBuilder let fallback: () -> Fallback

    private enum Piece {
        case text([ConsoleSegment])
        case custom(ConsoleCustomPreview)
    }

    private var candidates: [ConsoleRemoteObject] {
        segments.compactMap {
            if case .object(let object, _) = $0, object.objectId != nil { return object }
            return nil
        }
    }

    private var pieces: [Piece] {
        var output: [Piece] = []
        var run: [ConsoleSegment] = []
        for segment in segments {
            if case .object(let object, _) = segment, let preview = store.customHeader(object) {
                if !run.isEmpty { output.append(.text(run)); run = [] }
                output.append(.custom(preview))
            } else {
                run.append(segment)
            }
        }
        if !run.isEmpty { output.append(.text(run)) }
        return output
    }

    var body: some View {
        Group {
            if candidates.contains(where: { store.customHeader($0) != nil }) {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    ForEach(Array(pieces.enumerated()), id: \.offset) { index, piece in
                        switch piece {
                        case .text(let run):
                            Text(ConsoleText.attributed(run)).textSelection(.enabled)
                        case .custom(let preview):
                            ConsoleCustomHeaderView(session: session, store: store, preview: preview, targetID: targetID,
                                                    key: key + "/custom\(index)", depth: 0)
                        }
                    }
                }
            } else {
                fallback()
            }
        }
        .onAppear {
            for object in candidates { session.loadConsoleCustomHeader(object, targetID: targetID) }
        }
    }
}

/// A formatter's header, with a triangle that opens its body when
/// hasBody said there is one.
struct ConsoleCustomHeaderView: View {
    @ObservedObject var session: DeveloperToolsSession
    @ObservedObject var store: DeveloperConsoleStore
    let preview: ConsoleCustomPreview
    let targetID: String?
    let key: String
    let depth: Int

    private var open: Bool { store.expanded.contains(key) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                if preview.hasBody, depth < 20 {
                    ConsoleDisclosure(open: open, action: toggle)
                }
                ConsoleJsonMLRunsView(session: session, store: store, runs: ConsoleJsonMLLayout.inline(preview.header),
                                      objects: preview.objects, targetID: targetID, key: key + "/h", depth: depth)
                    .simultaneousGesture(TapGesture().onEnded { if preview.hasBody, depth < 20 { toggle() } })
            }
            if open, preview.hasBody {
                ConsoleCustomBodyView(session: session, store: store, preview: preview, targetID: targetID,
                                      key: key, depth: depth)
                    .padding(.leading, 14)
            }
        }
        .contextMenu {
            Button("Copy object") { session.copyConsoleObject(preview.object, targetID: targetID) }
            Button("Store as global variable") { session.storeConsoleObjectAsGlobal(preview.object, targetID: targetID) }
        }
    }

    private func toggle() {
        if open {
            store.collapse(key)
        } else {
            store.expanded.insert(key)
            session.loadConsoleCustomBody(preview, targetID: targetID)
        }
    }
}

/// The body a formatter returned, as lines.
private struct ConsoleCustomBodyView: View {
    @ObservedObject var session: DeveloperToolsSession
    @ObservedObject var store: DeveloperConsoleStore
    let preview: ConsoleCustomPreview
    let targetID: String?
    let key: String
    let depth: Int

    var body: some View {
        if let content = store.customBodies[ConsoleCustomFormatting.key(preview.object, config: preview.config)] {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array(ConsoleJsonMLLayout.lines(content.body).enumerated()), id: \.offset) { index, line in
                    ConsoleJsonMLRunsView(session: session, store: store, runs: line.runs, objects: content.objects,
                                          targetID: targetID, key: key + "/b\(index)", depth: depth)
                        .padding(.leading, line.indent)
                }
            }
        } else {
            Text("Loading…").foregroundStyle(.secondary)
                .onAppear { session.loadConsoleCustomBody(preview, targetID: targetID) }
        }
    }
}

/// One line of JsonML: styled text, and the objects it names, which open
/// as objects do (or through the formatters again).
private struct ConsoleJsonMLRunsView: View {
    @ObservedObject var session: DeveloperToolsSession
    @ObservedObject var store: DeveloperConsoleStore
    let runs: [ConsoleJsonMLLayout.Run]
    let objects: [Int: ConsoleRemoteObject]
    let targetID: String?
    let key: String
    let depth: Int

    private enum Piece {
        case text([ConsoleSegment])
        case object(ConsoleRemoteObject, config: ConsoleRemoteObject?)
    }

    private var pieces: [Piece] {
        var output: [Piece] = []
        var run: [ConsoleSegment] = []
        for item in runs {
            switch item {
            case .text(let text, let style):
                run.append(.text(text, style))
            case .object(let ref, let config):
                guard let object = objects[ref] else { continue }
                if !run.isEmpty { output.append(.text(run)); run = [] }
                output.append(.object(object, config: config.flatMap { objects[$0] }))
            }
        }
        if !run.isEmpty { output.append(.text(run)) }
        return output
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            ForEach(Array(pieces.enumerated()), id: \.offset) { index, piece in
                switch piece {
                case .text(let run):
                    Text(ConsoleText.attributed(run)).textSelection(.enabled)
                case .object(let object, let config):
                    ConsoleCustomObjectReference(session: session, store: store, object: object, config: config,
                                                 targetID: targetID, key: key + "/o\(index)", depth: depth + 1)
                }
            }
        }
    }
}

/// `["object", {object, config}]` in a formatter's JsonML: the formatters
/// get the first say again, with the config; otherwise it is an object
/// like any other in the console.
private struct ConsoleCustomObjectReference: View {
    @ObservedObject var session: DeveloperToolsSession
    @ObservedObject var store: DeveloperConsoleStore
    let object: ConsoleRemoteObject
    let config: ConsoleRemoteObject?
    let targetID: String?
    let key: String
    let depth: Int

    private var state: ConsoleCustomPreviewState? {
        store.customHeaders[ConsoleCustomFormatting.key(object, config: config)]
    }

    var body: some View {
        if object.objectId == nil || depth > 20 {
            Text(ConsoleText.attributed([.object(object, .plain)])).textSelection(.enabled)
        } else if let preview = store.customHeader(object, config: config) {
            ConsoleCustomHeaderView(session: session, store: store, preview: preview, targetID: targetID,
                                    key: key, depth: depth)
        } else if state == ConsoleCustomPreviewState.none || !store.settings.customFormatters {
            ConsoleValueLine(session: session, store: store, name: nil, object: object, targetID: targetID,
                             key: key, depth: depth)
        } else {
            Text(ConsoleText.attributed([.object(object, .plain)]))
                .onAppear { session.loadConsoleCustomHeader(object, config: config, targetID: targetID) }
        }
    }
}
