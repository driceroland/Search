import AppKit
import SwiftUI

/// A stack with its ignore-listed frames left out, as Chrome's Console
/// and Performance panel print one: the frames of ignored scripts behind
/// "Show N more frames". A stack that is all ignored shows in full, and an
/// async boundary shows only between frames that are shown.
enum DeveloperIgnoredFrames {
    static func filter<Frame>(_ frames: [Frame], isBoundary: (Frame) -> Bool = { _ in false },
                              isIgnored: (Frame) -> Bool) -> (frames: [Frame], hidden: Int) {
        let calls = frames.filter { !isBoundary($0) }
        let hidden = calls.filter(isIgnored).count
        guard hidden > 0, hidden < calls.count else { return (frames, 0) }
        var shown: [Frame] = []
        var boundary: Frame?
        for frame in frames {
            if isBoundary(frame) {
                if !shown.isEmpty { boundary = frame }
                continue
            }
            guard !isIgnored(frame) else { continue }
            if let pending = boundary { shown.append(pending) }
            boundary = nil
            shown.append(frame)
        }
        return (shown, hidden)
    }

    /// The toggle's title, as Chrome words it.
    static func toggleTitle(hidden: Int, showing: Bool) -> String {
        showing ? "Show less" : hidden == 1 ? "Show 1 more frame" : "Show \(hidden) more frames"
    }
}

/// A script or style location outside Sources, as Chrome links one: read
/// in its authored file when a source map has it, opening Sources there.
/// `line` and `column` are 1-based.
struct DeveloperSourceLocationLink: View {
    let session: DeveloperToolsSession
    let url: String
    let line: Int?
    var column: Int? = nil

    var body: some View {
        let link = session.sourceMaps.linked(url: url, line: line, column: column)
        let lineSuffix: String = link.line.map { ":\($0)" } ?? ""
        Button { session.revealConsoleSource(url: link.url, line: link.line) } label: {
            Text(ConsoleFormat.location(link.url, line: link.line))
                .font(DeveloperToolsStyle.code)
                .underline()
                .foregroundStyle(DeveloperToolsStyle.tint)
                .lineLimit(1).truncationMode(.middle)
        }
        .buttonStyle(.plain)
        .help("Open \(link.url)\(lineSuffix) in Sources")
        .onHover { inside in if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() } }
    }
}

extension ConsoleCallFrame {
    /// A frame with a file to link to, not a built-in's ("[native code]").
    var hasSource: Bool { !url.isEmpty && url != "[native code]" && url != "undefined" }
}

extension DeveloperPerformanceEvent {
    /// The script place a record names (a function call's, a script's, a
    /// sampled frame's), 1-based as WebKit gives it; nil for a record
    /// with none.
    var source: (url: String, line: Int?, column: Int?)? {
        let url: String?, line: String?, column: String?
        switch type {
        case "FunctionCall":
            url = data["scriptName"] ?? data["url"]
            line = data["scriptLine"] ?? data["lineNumber"]
            column = data["scriptColumn"] ?? data["columnNumber"]
        case "EvaluateScript", "JavaScriptFrame":
            url = data["url"]
            line = data["lineNumber"]
            column = data["columnNumber"]
        default:
            return nil
        }
        guard let url, !url.isEmpty else { return nil }
        return (url, line.flatMap { Int($0) }.flatMap { $0 > 0 ? $0 : nil },
                column.flatMap { Int($0) }.flatMap { $0 > 0 ? $0 : nil })
    }
}
