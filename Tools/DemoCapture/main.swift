import AppKit
import Foundation

// demo-capture: the Swift half of ./demo.
//
//   demo-capture selftest [offscreen|offscreen-active] [--record DIR]
//   demo-capture capture --window ID --out FILE.mov --stamps FILE.json [--fps 60] [--scale 2] [--codec hevc|h264|prores]
//       records until a line "stop" (or end of input) on stdin
//   demo-capture compose --plan PLAN.json
//       the recording onto a background, with the pointer drawn in, piped to ffmpeg

setvbuf(stdout, nil, _IOLBF, 0)
let args = Array(CommandLine.arguments.dropFirst())

func option(_ name: String) -> String? {
    guard let at = args.firstIndex(of: name), at + 1 < args.count else { return nil }
    return args[at + 1]
}

func say(_ object: [String: Any]) {
    if let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
       let line = String(data: data, encoding: .utf8) { print(line) }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

switch args.first {
case "selftest":
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    // selftest [PLACEMENT] [--record DIR]: DIR gets capture.mov and stamps.json, as `capture` writes them.
    let only = args.count > 1 && !args[1].hasPrefix("--") ? args[1] : nil
    let dir = option("--record")
    Task { @MainActor in
        await runSelftest(only: only ?? (dir == nil ? nil : "offscreen-active"), recordTo: dir)
        exit(0)
    }
    app.run()

case "capture":
    guard let idText = option("--window"), let id = UInt32(idText),
          let out = option("--out"), let stampsPath = option("--stamps")
    else { fail("usage: demo-capture capture --window ID --out FILE.mov --stamps FILE.json [--fps 60] [--scale 2] [--codec hevc]") }
    let fps = Int(option("--fps") ?? "60") ?? 60
    let scale = CGFloat(Double(option("--scale") ?? "2") ?? 2)
    let codec = option("--codec") ?? "hevc"
    guard CGPreflightScreenCaptureAccess() else {
        say(["error": "screen-recording-denied",
             "message": "Screen Recording is not allowed for the app that started demo-capture (its responsible app: the terminal or Claude). Allow it in System Settings › Privacy & Security › Screen & System Audio Recording."])
        exit(2)
    }
    Task {
        do {
            let window = try await shareableWindow(id)
            let recorder = WindowRecorder(window: window, scale: scale)
            try recorder.record(to: URL(fileURLWithPath: out), codec: codec)
            let offset = hostToWall()
            try await recorder.start(fps: fps)
            let came = await recorder.waitFirst(timeout: 5)
            say(["ready": came, "wall": Date().timeIntervalSince1970, "size": [Int(recorder.size.width), Int(recorder.size.height)],
                 "windowPoints": [Double(window.frame.width), Double(window.frame.height)], "onScreen": window.isOnScreen])
            // Until told to stop.
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                Thread.detachNewThread {
                    while let line = readLine() { if line.trimmingCharacters(in: .whitespaces) == "stop" { break } }
                    done.resume()
                }
            }
            await recorder.stop()
            let stamps: [String: Any] = ["hostToWall": offset, "stamps": recorder.stamps, "size": [Int(recorder.size.width), Int(recorder.size.height)],
                                         "complete": recorder.complete, "idle": recorder.idle, "dropped": recorder.dropped]
            try JSONSerialization.data(withJSONObject: stamps).write(to: URL(fileURLWithPath: stampsPath))
            var summary: [String: Any] = ["done": true, "frames": recorder.stamps.count, "idle": recorder.idle, "dropped": recorder.dropped]
            if let error = recorder.stopError { summary["streamError"] = error }
            say(summary)
            exit(0)
        } catch {
            say(["error": "capture", "message": "\(error)"])
            exit(1)
        }
    }
    dispatchMain()

case "compose":
    guard let plan = option("--plan") else { fail("usage: demo-capture compose --plan PLAN.json") }
    do {
        try compose(planPath: plan)
        exit(0)
    } catch {
        fail("compose: \(error)")
    }

default:
    fail("usage: demo-capture selftest | capture … | compose --plan PLAN.json")
}
