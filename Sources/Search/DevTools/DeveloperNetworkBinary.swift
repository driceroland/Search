import AppKit
import SwiftUI

/// The three ways Chrome's binary response view reads bytes.
enum DeveloperBinaryMode: String, CaseIterable, Identifiable {
    case base64 = "Base64"
    case hex = "Hex viewer"
    case utf8 = "UTF-8"

    var id: Self { self }

    /// The format name in "Copy as …".
    var copyName: String {
        switch self {
        case .base64: return "Base64"
        case .hex: return "Hex"
        case .utf8: return "UTF-8"
        }
    }
}

/// Formats a binary response body as Base64, a hex dump or UTF-8 text.
enum DeveloperBinaryFormat {
    static let bytesPerRow = 16
    /// How much of a body the view draws at first, and adds per "Show more".
    static let renderLimit = 1_048_576

    private static let digits = Array("0123456789abcdef".utf8)

    /// A hex dump, 16 bytes a row: an 8-digit offset, the bytes in hex
    /// (a wider gap after the eighth), then the bytes as ASCII with
    /// anything unprintable as ".". A short last row keeps the ASCII
    /// column where the full rows have it.
    static func hexDump(_ data: Data, limit: Int = Int.max) -> String {
        let bytes = [UInt8](data.prefix(max(0, limit)))
        var out = [UInt8]()
        out.reserveCapacity((bytes.count / bytesPerRow + 1) * 78)
        var start = 0
        while start < bytes.count {
            if start > 0 { out.append(0x0A) }
            let end = min(start + bytesPerRow, bytes.count)
            for shift in stride(from: 28, through: 0, by: -4) {
                out.append(digits[(start >> shift) & 0xF])
            }
            out.append(0x20)
            out.append(0x20)
            for column in 0..<bytesPerRow {
                if column == bytesPerRow / 2 { out.append(0x20) }
                if start + column < end {
                    let byte = bytes[start + column]
                    out.append(digits[Int(byte >> 4)])
                    out.append(digits[Int(byte & 0xF)])
                } else {
                    out.append(0x20)
                    out.append(0x20)
                }
                out.append(0x20)
            }
            out.append(0x20)
            for index in start..<end {
                let byte = bytes[index]
                out.append(byte >= 0x20 && byte < 0x7F ? byte : 0x2E)
            }
            start = end
        }
        return String(decoding: out, as: UTF8.self)
    }

    static func base64(_ data: Data, limit: Int = Int.max) -> String {
        data.prefix(max(0, limit)).base64EncodedString()
    }

    /// The bytes read as UTF-8, a malformed sequence as U+FFFD, as
    /// Chrome's TextDecoder does.
    static func utf8(_ data: Data, limit: Int = Int.max) -> String {
        String(decoding: data.prefix(max(0, limit)), as: UTF8.self)
    }

    static func text(_ data: Data, mode: DeveloperBinaryMode, limit: Int = Int.max) -> String {
        switch mode {
        case .base64: return base64(data, limit: limit)
        case .hex: return hexDump(data, limit: limit)
        case .utf8: return utf8(data, limit: limit)
        }
    }
}

/// Chrome's view of a binary response: Base64, Hex viewer or UTF-8, and
/// buttons that copy the whole body in each.
struct DeveloperBinaryResponseView: View {
    let data: Data

    @State private var mode: DeveloperBinaryMode = .base64
    @State private var limit = DeveloperBinaryFormat.renderLimit
    @State private var text = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: DeveloperToolsStyle.controlSpacing) {
                Picker("", selection: $mode) {
                    ForEach(DeveloperBinaryMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                .fixedSize()
                .accessibilityIdentifier("developer-network-binary-mode")
                Spacer(minLength: 0)
                ForEach(DeveloperBinaryMode.allCases) { format in
                    Button("Copy as \(format.copyName)") {
                        DeveloperToolsSession.copyToPasteboard(DeveloperBinaryFormat.text(data, mode: format))
                    }
                    .controlSize(.small)
                }
            }
            .font(.system(size: 11))
            .padding(.horizontal, DeveloperToolsStyle.gutter)
            .padding(.vertical, 4)
            .background(DeveloperToolsStyle.chrome)
            .overlay(alignment: .bottom) { Rectangle().fill(DeveloperToolsStyle.rule.opacity(0.55)).frame(height: 1) }

            DeveloperPlainTextView(text: text)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if data.count > limit {
                HStack(spacing: DeveloperToolsStyle.gutter) {
                    Text("Showing the first \(Self.size(limit)) of \(Self.size(data.count)).")
                        .foregroundStyle(.secondary)
                    Button("Show more") { limit += DeveloperBinaryFormat.renderLimit }
                        .buttonStyle(.plain)
                        .foregroundStyle(DeveloperToolsStyle.tint)
                    Spacer(minLength: 0)
                }
                .font(.system(size: 11))
                .padding(.horizontal, DeveloperToolsStyle.gutter)
                .padding(.vertical, 4)
                .background(DeveloperToolsStyle.chrome)
            }
        }
        .task(id: "\(mode.rawValue):\(limit)") {
            text = DeveloperBinaryFormat.text(data, mode: mode, limit: limit)
        }
        .accessibilityIdentifier("developer-network-binary")
    }

    private static func size(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

/// Read-only monospaced text in an AppKit text view, which keeps a
/// megabyte or more of hex scrolling smoothly.
struct DeveloperPlainTextView: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        if let view = scroll.documentView as? NSTextView {
            view.isEditable = false
            view.isSelectable = true
            view.isRichText = false
            view.drawsBackground = false
            view.textContainerInset = NSSize(width: 8, height: 6)
            view.font = Self.font
            view.textColor = .labelColor
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView, view.string != text else { return }
        view.string = text
        view.font = Self.font
        view.textColor = .labelColor
    }

    private static let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
}
