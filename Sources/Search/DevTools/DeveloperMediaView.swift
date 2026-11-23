import SwiftUI

/// Chrome's Media drawer tool: the page's players on the left (named by
/// their source file, with the frame they're in; hovering one draws its
/// element on the page, clicking reveal shows it in Elements), and on the
/// right the selected player's buffered and played timeline over tabs for
/// its Properties, Events and Messages.
struct DeveloperMediaView: View {
    let session: DeveloperToolsSession
    @ObservedObject private var media: DeveloperMediaModel
    @State private var tab = Tab.properties

    enum Tab: String, CaseIterable, Identifiable {
        case properties = "Properties"
        case events = "Events"
        case messages = "Messages"
        var id: Self { self }
    }

    init(session: DeveloperToolsSession) {
        self.session = session
        media = DeveloperMediaModel.model(for: session)
    }

    var body: some View {
        VStack(spacing: 0) {
            if let problem = media.problem {
                HStack {
                    Text(problem).foregroundStyle(.secondary).textSelection(.enabled)
                    Spacer()
                    DeveloperPanelIcon(symbol: "xmark", title: "Dismiss", size: 16) { media.dismissProblem() }
                }
                .padding(.horizontal, DeveloperToolsStyle.gutter).padding(.vertical, 4)
                .background(DeveloperToolsStyle.raised)
                Divider()
            }
            if media.players.isEmpty {
                VStack(spacing: 6) {
                    Text("No media players found").fontWeight(.semibold)
                    Text("Players appear here as the page creates <video> and <audio> elements. Reload the page to see players created before the Media tool opened, with their Media Source details.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    list.frame(minWidth: 170, idealWidth: 220, maxWidth: 300)
                    Divider()
                    if let player = media.selected {
                        detail(player).frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
        .font(.system(size: 11))
        .onAppear { media.start() }
        .onDisappear { media.stop() }
        .accessibilityIdentifier("developer-media")
    }

    // MARK: Players

    private var list: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Players").fontWeight(.semibold)
                Spacer()
                DeveloperPanelIcon(symbol: "nosign", title: "Clear players", size: 18) { media.clearPlayers() }
            }
            .padding(.horizontal, DeveloperToolsStyle.gutter)
            .frame(height: DeveloperToolsStyle.toolbarHeight)
            .background(DeveloperToolsStyle.chrome)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(media.players) { player in row(player) }
                }
            }
        }
    }

    private func row(_ player: DeveloperMediaPlayer) -> some View {
        let selected = media.selected?.id == player.id
        return HStack(spacing: 6) {
            Image(systemName: player.tag == "audio" ? "speaker.wave.2" : "play.rectangle")
                .foregroundStyle(player.errorCode != nil ? Color.red : .secondary)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(player.name).lineLimit(1).truncationMode(.middle)
                Text(player.frame + " · " + player.playback + (player.connected ? "" : " · not in document"))
                    .foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DeveloperToolsStyle.gutter)
        .frame(height: 34)
        .background(selected ? DeveloperToolsStyle.selected : .clear)
        .contentShape(Rectangle())
        .onTapGesture { media.selection = player.id }
        .onHover { inside in media.hover(inside ? player.id : nil) }
        .contextMenu {
            Button("Reveal in Elements panel") { media.reveal(player.id) }.disabled(!player.connected)
            Button("Copy source URL") { DeveloperToolsSession.copyToPasteboard(player.currentSrc) }
                .disabled(player.currentSrc.isEmpty)
        }
        .help(player.currentSrc.isEmpty ? player.label : player.currentSrc)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: Detail

    private func detail(_ player: DeveloperMediaPlayer) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: DeveloperToolsStyle.controlSpacing) {
                Picker("Tab", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
                if tab == .events {
                    DeveloperPanelIcon(symbol: "nosign", title: "Clear events", size: 18) { media.clearEvents(player.id) }
                }
                DeveloperPanelIcon(symbol: "arrow.up.forward.square", title: "Reveal in Elements panel", size: 18) {
                    media.reveal(player.id)
                }
                .disabled(!player.connected || !session.ready)
            }
            .padding(.horizontal, DeveloperToolsStyle.gutter)
            .frame(height: DeveloperToolsStyle.toolbarHeight)
            .background(DeveloperToolsStyle.chrome)
            Divider()
            DeveloperMediaTimeline(player: player)
                .padding(.horizontal, DeveloperToolsStyle.gutter)
                .padding(.vertical, 6)
            Divider()
            switch tab {
            case .properties: properties(player)
            case .events: events(player)
            case .messages: messages(player)
            }
        }
    }

    private func properties(_ player: DeveloperMediaPlayer) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                section("Source", [
                    ("currentSrc", player.currentSrc.isEmpty ? "—" : player.currentSrc),
                    ("Source type", sourceDescription(player)),
                    ("Element", "<\(player.tag)> " + player.label),
                    ("Frame", player.topFrame ? "top (\(player.frameURL))" : player.frameURL),
                    ("In document", player.connected ? "yes" : "no"),
                ])
                section("Playback", [
                    ("State", player.playback),
                    ("currentTime", DeveloperMediaTime.clock(player.currentTime)),
                    ("duration", player.duration.map { DeveloperMediaTime.clock($0) } ?? (player.durationText ?? "—")),
                    ("readyState", DeveloperMediaState.readyState(player.readyState)),
                    ("networkState", DeveloperMediaState.networkState(player.networkState)),
                    ("paused", flag(player.paused)), ("ended", flag(player.ended)), ("seeking", flag(player.seeking)),
                    ("playbackRate", player.playbackRate.formatted()),
                    ("volume", player.volume.formatted() + (player.muted ? " (muted)" : "")),
                    ("loop", flag(player.loop)), ("autoplay", flag(player.autoplay)),
                    ("controls", flag(player.controls)), ("preload", player.preload.isEmpty ? "—" : player.preload),
                ])
                section("Buffering", [
                    ("buffered", DeveloperMediaRanges.format(player.buffered)),
                    ("Buffered ahead", DeveloperMediaTime.seconds(DeveloperMediaRanges.ahead(player.buffered, at: player.currentTime)) + " s"),
                    ("played", DeveloperMediaRanges.format(player.played)),
                    ("seekable", DeveloperMediaRanges.format(player.seekable)),
                ])
                if player.tag == "video" {
                    section("Video", [
                        ("Resolution", player.videoWidth > 0 ? "\(player.videoWidth)×\(player.videoHeight)" : "—"),
                        ("Decoded frames", player.decodedFrames.map(String.init) ?? "—"),
                        ("Dropped frames", player.droppedFrames.map(String.init) ?? "—"),
                        ("Corrupted frames", player.corruptedFrames.map(String.init) ?? "—"),
                    ])
                }
                let tracks = trackRows(player)
                if !tracks.isEmpty { section("Tracks", tracks) }
                if player.sourceKind == "MSE" || !player.mseMimeTypes.isEmpty {
                    section(player.mseManaged ? "ManagedMediaSource" : "MediaSource", [
                        ("readyState", player.mseReadyState ?? "—"),
                        ("SourceBuffers", player.mseMimeTypes.isEmpty ? "none" : player.mseMimeTypes.joined(separator: "\n")),
                    ])
                }
                if player.hasMediaKeys || !player.initDataTypes.isEmpty || player.keySystem != nil {
                    section("Encrypted media", [
                        ("mediaKeys", player.hasMediaKeys ? "set" : "none"),
                        ("Key system", player.keySystem ?? "—"),
                        ("initDataType", player.initDataTypes.isEmpty ? "—" : player.initDataTypes.joined(separator: ", ")),
                    ])
                }
                if let code = player.errorCode {
                    section("Error", [
                        ("code", DeveloperMediaState.errorCode(code) + " (\(code))"),
                        ("message", player.errorMessage ?? "—"),
                    ])
                }
            }
            .padding(DeveloperToolsStyle.gutter)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func sourceDescription(_ player: DeveloperMediaPlayer) -> String {
        switch player.sourceKind {
        case "MSE": "Media Source Extensions (blob:)"
        case "blob": "Blob URL"
        case "File": "File (URL)"
        case "data": "Data URL"
        case "MediaStream": "MediaStream (srcObject)"
        case "srcObject": "srcObject"
        default: "None"
        }
    }

    private func trackRows(_ player: DeveloperMediaPlayer) -> [(String, String)] {
        func text(_ list: [DeveloperMediaPlayer.Track]) -> String {
            list.map { track in
                [track.kind, track.label, track.language].filter { !$0.isEmpty }.joined(separator: " · ")
                    + (track.on ? " (on)" : "")
            }.joined(separator: "\n")
        }
        var rows: [(String, String)] = []
        if !player.audioTracks.isEmpty { rows.append(("Audio tracks", text(player.audioTracks))) }
        if !player.videoTracks.isEmpty { rows.append(("Video tracks", text(player.videoTracks))) }
        if !player.textTracks.isEmpty { rows.append(("Text tracks", text(player.textTracks))) }
        return rows
    }

    private func flag(_ value: Bool) -> String { value ? "true" : "false" }

    private func section(_ title: String, _ rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).fontWeight(.semibold)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(row.0).foregroundStyle(.secondary).frame(width: 130, alignment: .leading)
                    Text(row.1).font(DeveloperToolsStyle.code).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func events(_ player: DeveloperMediaPlayer) -> some View {
        let log = media.log(player.id)
        let start = log.first?.time ?? 0
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Timestamp").frame(width: 84, alignment: .leading)
                Text("Event").frame(width: 120, alignment: .leading)
                Text("currentTime").frame(width: 84, alignment: .leading)
                Text("Detail").frame(maxWidth: .infinity, alignment: .leading)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, DeveloperToolsStyle.gutter)
            .frame(height: 20)
            .background(DeveloperToolsStyle.raised)
            Divider()
            if log.isEmpty {
                Text("No events yet.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(log) { event in
                                HStack(spacing: 8) {
                                    Text(DeveloperMediaTime.offset(event.time, from: start))
                                        .frame(width: 84, alignment: .leading)
                                        .help(Date(timeIntervalSince1970: event.time / 1_000).formatted(date: .omitted, time: .standard))
                                    Text(event.name).frame(width: 120, alignment: .leading)
                                        .foregroundStyle(DeveloperMediaState.isTrouble(event.name) ? Color.orange : Palette.ink)
                                    Text(DeveloperMediaTime.clock(event.mediaTime)).frame(width: 84, alignment: .leading)
                                    Text(event.detail ?? "").foregroundStyle(.secondary).lineLimit(1)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .font(DeveloperToolsStyle.code)
                                .textSelection(.enabled)
                                .padding(.horizontal, DeveloperToolsStyle.gutter)
                                .frame(height: 18)
                                .id(event.id)
                            }
                        }
                    }
                    .onChange(of: log.last?.id) { _, last in
                        if let last { proxy.scrollTo(last, anchor: .bottom) }
                    }
                }
            }
        }
    }

    private func messages(_ player: DeveloperMediaPlayer) -> some View {
        let messages = media.messages(for: player)
        return Group {
            if messages.isEmpty {
                Text("No messages.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(messages) { message in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Image(systemName: message.level == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                                    .foregroundStyle(message.level == .error ? Color.red : Color.orange)
                                Text(message.text).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.horizontal, DeveloperToolsStyle.gutter)
                            .padding(.vertical, 3)
                            Divider()
                        }
                    }
                }
            }
        }
    }
}

/// The selected player's timeline: buffered ranges under played ones,
/// with the playhead, as Chrome's player timeline draws them.
struct DeveloperMediaTimeline: View {
    let player: DeveloperMediaPlayer

    var body: some View {
        let duration = player.duration
        VStack(alignment: .leading, spacing: 3) {
            GeometryReader { proxy in
                let width = proxy.size.width
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2).fill(DeveloperToolsStyle.raised)
                    ForEach(Array(DeveloperMediaRanges.fractions(player.buffered, duration: duration).enumerated()), id: \.offset) { _, part in
                        Rectangle().fill(DeveloperToolsStyle.tint.opacity(0.35))
                            .frame(width: max(1, (part.end - part.start) * width))
                            .offset(x: part.start * width)
                    }
                    ForEach(Array(DeveloperMediaRanges.fractions(player.played, duration: duration).enumerated()), id: \.offset) { _, part in
                        Rectangle().fill(DeveloperToolsStyle.tint)
                            .frame(width: max(1, (part.end - part.start) * width), height: 4)
                            .offset(x: part.start * width)
                    }
                    if let duration, duration.isFinite, duration > 0 {
                        Rectangle().fill(Color.red)
                            .frame(width: 2)
                            .offset(x: min(max(player.currentTime / duration, 0), 1) * width - 1)
                    }
                }
            }
            .frame(height: 12)
            .accessibilityLabel("Buffered " + DeveloperMediaRanges.format(player.buffered))
            HStack {
                Text(DeveloperMediaTime.clock(player.currentTime) + " / "
                     + (player.duration.map { DeveloperMediaTime.clock($0) } ?? (player.durationText ?? "—")))
                Spacer()
                HStack(spacing: 4) {
                    Circle().fill(DeveloperToolsStyle.tint.opacity(0.35)).frame(width: 7, height: 7)
                    Text("Buffered")
                    Circle().fill(DeveloperToolsStyle.tint).frame(width: 7, height: 7)
                    Text("Played")
                    Rectangle().fill(Color.red).frame(width: 2, height: 8)
                    Text("Playhead")
                }
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
        }
    }
}
