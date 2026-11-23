import XCTest
@testable import Search

/// The Media drawer's pure logic: state names, the event log ring, time
/// ranges in words and on the bar, times, player names, parsing the page
/// script's report and which console lines count as media messages.
final class DeveloperMediaTests: XCTestCase {
    // MARK: State names

    func testReadyAndNetworkStatesUseTheSpecsNames() {
        XCTAssertEqual(DeveloperMediaState.readyState(0), "HAVE_NOTHING")
        XCTAssertEqual(DeveloperMediaState.readyState(1), "HAVE_METADATA")
        XCTAssertEqual(DeveloperMediaState.readyState(2), "HAVE_CURRENT_DATA")
        XCTAssertEqual(DeveloperMediaState.readyState(3), "HAVE_FUTURE_DATA")
        XCTAssertEqual(DeveloperMediaState.readyState(4), "HAVE_ENOUGH_DATA")
        XCTAssertEqual(DeveloperMediaState.readyState(9), "9")
        XCTAssertEqual(DeveloperMediaState.readyState(nil), "—")
        XCTAssertEqual(DeveloperMediaState.networkState(0), "NETWORK_EMPTY")
        XCTAssertEqual(DeveloperMediaState.networkState(1), "NETWORK_IDLE")
        XCTAssertEqual(DeveloperMediaState.networkState(2), "NETWORK_LOADING")
        XCTAssertEqual(DeveloperMediaState.networkState(3), "NETWORK_NO_SOURCE")
    }

    func testMediaErrorCodesUseTheSpecsNames() {
        XCTAssertEqual(DeveloperMediaState.errorCode(1), "MEDIA_ERR_ABORTED")
        XCTAssertEqual(DeveloperMediaState.errorCode(2), "MEDIA_ERR_NETWORK")
        XCTAssertEqual(DeveloperMediaState.errorCode(3), "MEDIA_ERR_DECODE")
        XCTAssertEqual(DeveloperMediaState.errorCode(4), "MEDIA_ERR_SRC_NOT_SUPPORTED")
    }

    func testTheListenedEventsCoverChromesListAndTroubleIsMarked() {
        for name in ["loadstart", "loadedmetadata", "canplay", "play", "playing", "pause", "seeking", "seeked", "waiting",
                     "stalled", "ended", "error", "ratechange", "volumechange", "resize", "emptied", "durationchange"] {
            XCTAssertTrue(DeveloperMediaState.events.contains(name), name)
        }
        XCTAssertTrue(DeveloperMediaState.isTrouble("stalled"))
        XCTAssertFalse(DeveloperMediaState.isTrouble("playing"))
    }

    // MARK: Event log

    func testTheLogKeepsTheNewestEntriesAndCountsTheDropped() {
        var log = DeveloperMediaEventLog<Int>(capacity: 3)
        log.append(contentsOf: [1, 2])
        XCTAssertEqual(log.entries, [1, 2])
        XCTAssertEqual(log.dropped, 0)
        log.append(contentsOf: [3, 4, 5])
        XCTAssertEqual(log.entries, [3, 4, 5])
        XCTAssertEqual(log.dropped, 2)
        log.removeAll()
        XCTAssertTrue(log.isEmpty)
        XCTAssertEqual(log.dropped, 0)
    }

    func testALogHoldsAtLeastOneEntry() {
        var log = DeveloperMediaEventLog<String>(capacity: 0)
        log.append("a")
        log.append("b")
        XCTAssertEqual(log.entries, ["b"])
    }

    func testAnEventReadsThePageScriptsFields() throws {
        let event = try XCTUnwrap(DeveloperMediaEvent(["seq": 4, "name": "resize", "time": 1_700_000_000_123.5,
                                                       "mediaTime": 2.5, "detail": "640×360"]))
        XCTAssertEqual(event.seq, 4)
        XCTAssertEqual(event.name, "resize")
        XCTAssertEqual(event.mediaTime, 2.5)
        XCTAssertEqual(event.detail, "640×360")
        XCTAssertNil(DeveloperMediaEvent(["seq": 1, "name": "play", "detail": ""])?.detail)
        XCTAssertNil(DeveloperMediaEvent(["name": "play"]))
    }

    // MARK: Ranges

    func testRangesParseAndSkipWhatIsntAPairOfNumbers() {
        let ranges = DeveloperMediaRanges.parse([[0, 12.5], [20, 30], ["x", 1] as [Any], [5]] as [Any])
        XCTAssertEqual(ranges, [DeveloperMediaRange(start: 0, end: 12.5), DeveloperMediaRange(start: 20, end: 30)])
        XCTAssertEqual(DeveloperMediaRanges.parse(nil), [])
    }

    func testRangesAreSaidInSeconds() {
        XCTAssertEqual(DeveloperMediaRanges.format([]), "none")
        XCTAssertEqual(DeveloperMediaRanges.format([.init(start: 0, end: 12.5), .init(start: 20, end: 30)]),
                       "0.00–12.50 s, 20.00–30.00 s")
    }

    func testRangesBecomeFractionsOfTheDuration() {
        let parts = DeveloperMediaRanges.fractions([.init(start: 0, end: 25), .init(start: 50, end: 150)], duration: 100)
        XCTAssertEqual(parts.count, 2)
        XCTAssertEqual(parts[0].start, 0)
        XCTAssertEqual(parts[0].end, 0.25)
        XCTAssertEqual(parts[1].start, 0.5)
        XCTAssertEqual(parts[1].end, 1, "clamped to the bar")
    }

    func testWithoutAFiniteDurationTheBarRunsToTheLastRange() {
        let parts = DeveloperMediaRanges.fractions([.init(start: 10, end: 20), .init(start: 30, end: 40)], duration: .infinity)
        XCTAssertEqual(parts.count, 2)
        XCTAssertEqual(parts[0].start, 0.25)
        XCTAssertEqual(parts[1].end, 1)
        XCTAssertTrue(DeveloperMediaRanges.fractions([], duration: nil).isEmpty)
    }

    func testBufferedAheadIsMeasuredInTheRangeThePlayheadIsIn() {
        let ranges: [DeveloperMediaRange] = [.init(start: 0, end: 10), .init(start: 20, end: 35)]
        XCTAssertEqual(DeveloperMediaRanges.ahead(ranges, at: 4), 6)
        XCTAssertEqual(DeveloperMediaRanges.ahead(ranges, at: 25), 10)
        XCTAssertEqual(DeveloperMediaRanges.ahead(ranges, at: 15), 0)
    }

    // MARK: Times

    func testMediaTimesAreWrittenLikeAClock() {
        XCTAssertEqual(DeveloperMediaTime.clock(3.25), "3.250")
        XCTAssertEqual(DeveloperMediaTime.clock(123.25), "2:03.250")
        XCTAssertEqual(DeveloperMediaTime.clock(3_723.25), "1:02:03.250")
        XCTAssertEqual(DeveloperMediaTime.clock(.infinity), "∞")
        XCTAssertEqual(DeveloperMediaTime.clock(.nan), "NaN")
        XCTAssertEqual(DeveloperMediaTime.clock(nil), "—")
    }

    func testEventTimesAreOffsetsFromTheFirst() {
        XCTAssertEqual(DeveloperMediaTime.offset(2_500, from: 1_000), "+1.500 s")
        XCTAssertEqual(DeveloperMediaTime.offset(500, from: 1_000), "+0.000 s")
    }

    // MARK: Players

    func testPlayersAreNamedAfterTheirSourceFile() {
        XCTAssertEqual(DeveloperMediaNames.name(src: "https://cdn.example/videos/intro%20clip.mp4?x=1", kind: "File", tag: "video"),
                       "intro clip.mp4")
        XCTAssertEqual(DeveloperMediaNames.name(src: "https://example.com/", kind: "File", tag: "video"), "example.com")
        XCTAssertEqual(DeveloperMediaNames.name(src: "blob:https://example.com/1234", kind: "MSE", tag: "video"), "MediaSource (blob)")
        XCTAssertEqual(DeveloperMediaNames.name(src: "blob:https://example.com/1234", kind: "blob", tag: "video"), "blob")
        XCTAssertEqual(DeveloperMediaNames.name(src: "data:audio/wav;base64,AAAA", kind: "data", tag: "audio"), "data:audio/wav")
        XCTAssertEqual(DeveloperMediaNames.name(src: "", kind: "none", tag: "audio"), "<audio> (no source)")
        XCTAssertEqual(DeveloperMediaNames.name(src: "", kind: "MediaStream", tag: "video"), "MediaStream")
    }

    func testTheFrameLabelIsTopOrTheFramesHost() {
        XCTAssertEqual(DeveloperMediaNames.frame(url: "https://a.example/", top: true), "top")
        XCTAssertEqual(DeveloperMediaNames.frame(url: "https://player.example/embed/1", top: false), "player.example")
    }

    func testAPlayerReadsThePageScriptsDescription() {
        var player = DeveloperMediaPlayer(id: "d:1", document: "d")
        player.update([
            "tag": "video", "frameURL": "https://a.example/", "top": true, "connected": true,
            "currentSrc": "blob:https://a.example/9", "sourceKind": "MSE", "duration": 60, "currentTime": 12.5,
            "readyState": 4, "networkState": 2, "paused": false, "ended": false, "seeking": false,
            "playbackRate": 1.5, "volume": 0.5, "muted": true, "videoWidth": 1920, "videoHeight": 1080,
            "buffered": [[0, 30]], "played": [[0, 12.5]], "seekable": [[0, 60]],
            "quality": ["total": 300, "dropped": 3, "corrupted": 0],
            "audioTracks": [["kind": "main", "label": "English", "language": "en", "on": true] as [String: Any]],
            "mse": ["mimeTypes": ["video/mp4; codecs=\"avc1.64001f\"", "audio/mp4; codecs=\"mp4a.40.2\""],
                    "readyState": "open", "managed": false] as [String: Any],
            "mediaKeys": true, "keySystem": "com.apple.fps", "initDataTypes": ["sinf"],
            "error": ["code": 3, "message": "Decoder failed"] as [String: Any], "label": "video#main",
        ])
        XCTAssertEqual(player.sourceKind, "MSE")
        XCTAssertEqual(player.duration, 60)
        XCTAssertEqual(player.readyState, 4)
        XCTAssertFalse(player.paused)
        XCTAssertTrue(player.muted)
        XCTAssertEqual(player.buffered, [DeveloperMediaRange(start: 0, end: 30)])
        XCTAssertEqual(player.decodedFrames, 300)
        XCTAssertEqual(player.droppedFrames, 3)
        XCTAssertEqual(player.audioTracks.first?.language, "en")
        XCTAssertEqual(player.mseMimeTypes.count, 2)
        XCTAssertEqual(player.mseReadyState, "open")
        XCTAssertTrue(player.hasMediaKeys)
        XCTAssertEqual(player.keySystem, "com.apple.fps")
        XCTAssertEqual(player.initDataTypes, ["sinf"])
        XCTAssertEqual(player.errorCode, 3)
        XCTAssertEqual(player.playback, "Error")
        XCTAssertEqual(player.name, "MediaSource (blob)")
    }

    func testPlaybackSummary() {
        var player = DeveloperMediaPlayer(id: "d:1", document: "d")
        player.update(["paused": true, "readyState": 4])
        XCTAssertEqual(player.playback, "Paused")
        player.update(["paused": false, "readyState": 2])
        XCTAssertEqual(player.playback, "Buffering")
        player.update(["paused": false, "readyState": 4])
        XCTAssertEqual(player.playback, "Playing")
        player.update(["paused": true, "ended": true, "readyState": 4])
        XCTAssertEqual(player.playback, "Ended")
        XCTAssertNil(player.duration, "a NaN duration comes as text, not a number")
    }

    // MARK: Messages

    func testMediaConsoleLinesAreRecognised() {
        XCTAssertTrue(DeveloperMediaMessages.isMediaRelated("Unhandled Promise Rejection: NotAllowedError: play() failed"))
        XCTAssertTrue(DeveloperMediaMessages.isMediaRelated("Failed to execute 'appendBuffer' on 'SourceBuffer'"))
        XCTAssertTrue(DeveloperMediaMessages.isMediaRelated("The video codec isn't supported"))
        XCTAssertTrue(DeveloperMediaMessages.isMediaRelated("MSE: buffer full"))
        XCTAssertFalse(DeveloperMediaMessages.isMediaRelated("Failed to load resource: the server responded with 404"))
        XCTAssertFalse(DeveloperMediaMessages.isMediaRelated("hlsx is undefined"), "short words only as whole words")
    }

    func testMessagesHaveThePlayersErrorThenMediaWarnings() {
        var player = DeveloperMediaPlayer(id: "d:1", document: "d")
        player.update(["error": ["code": 4, "message": "Unsupported"] as [String: Any]])
        let messages = DeveloperMediaMessages.messages(for: player, errorTime: 10, console: [
            (level: "warning", text: "Autoplay was prevented for the audio element"),
            (level: "log", text: "video started"),
            (level: "error", text: "Uncaught TypeError: x is undefined"),
        ])
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0].level, .error)
        XCTAssertEqual(messages[0].text, "MEDIA_ERR_SRC_NOT_SUPPORTED (4): Unsupported")
        XCTAssertEqual(messages[1].level, .warning)
    }
}
