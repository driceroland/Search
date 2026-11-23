import AppKit
import AVKit
import CoreText
import SwiftUI
import UniformTypeIdentifiers

/// Which responses Preview draws as a font sample or a player.
enum DeveloperResponseMedia {
    enum Kind {
        case font, audio, video
    }

    private static let fontTypes: Set<String> = [
        "application/font-woff", "application/x-font-woff", "application/font-woff2", "application/x-font-woff2",
        "application/x-font-ttf", "application/x-font-truetype", "application/x-font-otf",
        "application/x-font-opentype", "application/font-sfnt", "application/vnd.ms-opentype",
        "application/font-ttf", "application/font-otf",
    ]
    private static let fontExtensions: Set<String> = ["woff", "woff2", "ttf", "otf", "ttc", "otc"]
    private static let audioExtensions: Set<String> = ["mp3", "m4a", "aac", "wav", "oga", "opus", "flac", "weba", "aif", "aiff"]
    private static let videoExtensions: Set<String> = ["mp4", "m4v", "mov", "webm", "ogv", "ogg"]

    /// The MIME type without its parameters.
    static func essence(_ mimeType: String?) -> String {
        (mimeType ?? "").split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
    }

    static func pathExtension(_ url: String) -> String {
        (URL(string: url)?.pathExtension ?? "").lowercased()
    }

    /// From the MIME type, or from the file's extension when the server
    /// sent a generic one.
    static func kind(mimeType: String?, url: String) -> Kind? {
        let mime = essence(mimeType)
        if mime.hasPrefix("font/") || fontTypes.contains(mime) { return .font }
        if mime.hasPrefix("audio/") { return .audio }
        if mime.hasPrefix("video/") { return .video }
        guard mime.isEmpty || mime == "application/octet-stream" || mime == "binary/octet-stream" else { return nil }
        let ending = pathExtension(url)
        if fontExtensions.contains(ending) { return .font }
        if audioExtensions.contains(ending) { return .audio }
        if videoExtensions.contains(ending) { return .video }
        return nil
    }

    /// The file extension the player needs to recognise the body.
    static func fileExtension(mimeType: String?, url: String) -> String {
        let mime = essence(mimeType)
        if !mime.isEmpty, mime != "application/octet-stream", let ending = UTType(mimeType: mime)?.preferredFilenameExtension {
            return ending
        }
        let ending = pathExtension(url)
        if !ending.isEmpty, ending.count <= 5 { return ending }
        switch mime {
        case "audio/mpeg": return "mp3"
        case "audio/mp4": return "m4a"
        case "audio/wav", "audio/x-wav", "audio/wave": return "wav"
        case "video/quicktime": return "mov"
        case "video/webm", "audio/webm": return "webm"
        default: return mime.hasPrefix("audio/") ? "m4a" : "mp4"
        }
    }

    /// Only while a preview plays: each file goes when its preview does,
    /// and the folder when the tools close (or, after a crash, when the
    /// package next starts).
    private static let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("Search Network Preview", isDirectory: true)

    static func clear() { try? FileManager.default.removeItem(at: folder) }

    /// The body in a temporary file the player can open.
    static func write(_ data: Data, fileExtension: String) -> URL? {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent(UUID().uuidString).appendingPathExtension(fileExtension)
            try data.write(to: file, options: .atomic)
            return file
        } catch {
            return nil
        }
    }

    static func remove(_ file: URL?) {
        guard let file, file.isFileURL, file.path.hasPrefix(folder.path) else { return }
        try? FileManager.default.removeItem(at: file)
    }
}

/// Chrome's font preview: the alphabet and digits in the font, at a
/// few sizes.
enum DeveloperFontSample {
    static let lines = ["ABCDEFGHIJKLMNOPQRSTUVWXYZ", "abcdefghijklmnopqrstuvwxyz", "1234567890"]
    static var text: String { lines.joined(separator: "\n") }
    static let sizes: [CGFloat] = [12, 18, 24, 36, 48]

    /// The faces in a font file (several for a collection), without
    /// registering them with the system.
    static func descriptors(_ data: Data) -> [CTFontDescriptor] {
        guard !data.isEmpty else { return [] }
        return (CTFontManagerCreateFontDescriptorsFromData(data as CFData) as? [CTFontDescriptor]) ?? []
    }

    /// The file's first face at each sample size.
    static func fonts(_ data: Data) -> [CTFont] {
        guard let first = descriptors(data).first else { return [] }
        return sizes.map { CTFontCreateWithFontDescriptor(first, $0, nil) }
    }

    static func name(_ font: CTFont) -> String {
        CTFontCopyFullName(font) as String
    }
}

struct DeveloperFontPreview: View {
    let data: Data

    @State private var fonts: [CTFont] = []
    @State private var loaded = false

    var body: some View {
        Group {
            if let first = fonts.first {
                ScrollView {
                    VStack(alignment: .leading, spacing: DeveloperToolsStyle.gutter * 2) {
                        Text(DeveloperFontSample.name(first))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        ForEach(Array(fonts.enumerated()), id: \.offset) { _, font in
                            Text(DeveloperFontSample.text)
                                .font(Font(font))
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(DeveloperToolsStyle.gutter * 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if loaded {
                Text("This request has no preview available.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .padding(DeveloperToolsStyle.gutter * 2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Color.clear
            }
        }
        .task(id: data.count) {
            fonts = DeveloperFontSample.fonts(data)
            loaded = true
        }
        .accessibilityIdentifier("developer-network-font-preview")
    }
}

/// An audio or video response in a player: the body from a temporary
/// file, or the request's address when WebKit kept no body.
struct DeveloperMediaPreview: View {
    let data: Data?
    let url: String
    let mimeType: String?
    let audio: Bool

    @State private var file: URL?
    @State private var written: URL?
    @State private var loaded = false

    var body: some View {
        Group {
            if let file {
                DeveloperPlayerView(url: file)
                    .frame(maxWidth: 640, maxHeight: audio ? 64 : 360)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if loaded {
                Text("This request has no preview available.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .padding(DeveloperToolsStyle.gutter * 2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Color.clear
            }
        }
        .task(id: url + ":\(data?.count ?? -1)") {
            DeveloperResponseMedia.remove(written)
            written = nil
            if let data, !data.isEmpty {
                written = DeveloperResponseMedia.write(data, fileExtension: DeveloperResponseMedia.fileExtension(mimeType: mimeType, url: url))
                file = written
            } else if let remote = URL(string: url), ["http", "https"].contains(remote.scheme?.lowercased() ?? "") {
                file = remote
            } else {
                file = nil
            }
            loaded = true
        }
        .onDisappear {
            DeveloperResponseMedia.remove(written)
            written = nil
        }
        .accessibilityIdentifier("developer-network-media-preview")
    }
}

private struct DeveloperPlayerView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.player = AVPlayer(url: url)
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if (view.player?.currentItem?.asset as? AVURLAsset)?.url != url {
            view.player?.pause()
            view.player = AVPlayer(url: url)
        }
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player?.pause()
        view.player = nil
    }
}
