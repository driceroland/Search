import AppKit
import AuthenticationServices
import SwiftUI
import WebKit

#if DEBUG
// Extensions, driven: installing, pressing, answering, recording.
extension Bench {
    /// Extensions, from the shell. Installing asks as it always does, except
    /// in a test run given `yes` — a real browser can't be made to skip it.
    @available(macOS 15.4, *)
    func extensionCommand(_ verb: String, _ request: [String: Any], browser: Browser, _ answer: @escaping ([String: Any]) -> Void) {
        let extensions = Extensions.shared
        let skip = Store.testing && (request["yes"] as? Bool ?? false)
        switch verb {
        case "extensions":
            answer(["started": extensions.started, "busy": extensions.busy ?? "", "extensions": extensions.installed.map { item -> [String: Any] in
                let context = extensions.contexts[item.id]
                let action = context.flatMap { $0.action(for: extensions.activeAdapter(for: $0)) }
                return [
                    "id": item.id, "name": item.name, "version": item.version, "enabled": item.enabled,
                    "loaded": context != nil, "private": context?.hasAccessToPrivateData ?? false,
                    "base": context?.baseURL.absoluteString ?? "",
                    "errors": (context?.errors ?? []).map { error in
                        let e = error as NSError
                        let under = (e.userInfo[NSUnderlyingErrorKey] as? NSError).map { " ← \($0.localizedDescription) \($0.userInfo)" } ?? ""
                        return e.localizedDescription + under + (e.userInfo.isEmpty ? "" : " \(e.userInfo.filter { $0.key != NSLocalizedDescriptionKey && $0.key != NSUnderlyingErrorKey })")
                    },
                    "reported": extensions.errors[item.id] ?? [],
                    "action": action?.label ?? "", "badge": action?.badgeText ?? "",
                    "popup": action?.presentsPopup ?? false,
                    "pinned": item.pinned ?? false, "source": item.source ?? "",
                ]
            }])
        case "ext-add":
            guard let text = request["id"] as? String else { answer(["error": "ext-add needs an id or link"]); return }
            extensions.install(from: text, confirm: !skip)
            answer(["started": true])
        case "ext-folder":
            guard let path = request["path"] as? String else { answer(["error": "ext-folder needs a path"]); return }
            extensions.installFolder(at: URL(fileURLWithPath: path), confirm: !skip)
            answer(["started": true])
        case "ext-press":
            guard let id = request["id"] as? String else { answer(["error": "ext-press needs an id"]); return }
            extensions.press(id)
            answer(["pressed": true])
        case "ext-enable":
            guard let id = request["id"] as? String else { answer(["error": "ext-enable needs an id"]); return }
            extensions.setEnabled(id, request["on"] as? Bool ?? true)
            answer(["enabled": request["on"] as? Bool ?? true])
        case "ext-private":
            guard Store.testing else { answer(["error": "only in a test run"]); return }
            guard let id = request["id"] as? String, let context = extensions.contexts[id] else {
                answer(["error": "ext-private needs a loaded extension's id"]); return
            }
            extensions.setPrivate(id, request["on"] as? Bool ?? true)
            answer(["private": context.hasAccessToPrivateData])
        case "capture":
            // Extensions' screen recording: ids given, what is recording, who
            // may, and the last request with its answer.
            answer(ExtensionCapture.shared.state)
        case "capture-stop":
            guard let id = request["id"] as? String else { answer(["error": "capture-stop needs an id"]); return }
            ExtensionCapture.shared.stop(id)
            answer(["stopping": id])
        case "ext-answer":
            // In a test run: answer every extension's question yes or no
            // without asking, or go back to asking.
            guard Store.testing else { answer(["error": "only in a test run"]); return }
            switch request["answer"] as? String {
            case "yes": extensions.answerForTests = true
            case "no": extensions.answerForTests = false
            default: extensions.answerForTests = nil
            }
            answer(["answer": request["answer"] as? String ?? "ask", "asked": extensions.asked])
        case "ext-shot":
            // A picture of the extension's popup, while it is open.
            guard let id = request["id"] as? String, ExtensionPopup.shared.extensionID == id,
                  let web = ExtensionPopup.shared.view, let path = request["path"] as? String
            else { answer(["error": "no popup open for that extension"]); return }
            shoot(web, to: URL(fileURLWithPath: path), width: nil, answer)
        case "ext-menu":
            // The list behind the puzzle button, as a picture.
            guard let path = request["path"] as? String, let data = extensionMenuPicture()?.representation(using: .png, properties: [:]) else {
                answer(["error": "ext-menu needs a path"])
                return
            }
            do { try data.write(to: URL(fileURLWithPath: path)); answer(["saved": path]) }
            catch { answer(["error": error.localizedDescription]) }
        case "ext-pin":
            guard let id = request["id"] as? String else { answer(["error": "ext-pin needs an id"]); return }
            extensions.setPinned(id, request["on"] as? Bool ?? true)
            answer(["pinned": request["on"] as? Bool ?? true])
        case "ext-reload":
            guard let id = request["id"] as? String else { answer(["error": "ext-reload needs an id"]); return }
            extensions.reload(id)
            answer(["reloading": true])
        case "ext-remove":
            guard let id = request["id"] as? String else { answer(["error": "ext-remove needs an id"]); return }
            extensions.remove(id)
            answer(["removed": true])
        case "ext-popup":
            // JavaScript in the extension's popup, while it is open.
            guard let id = request["id"] as? String, ExtensionPopup.shared.extensionID == id,
                  let web = ExtensionPopup.shared.view
            else { answer(["error": "no popup open for that extension"]); return }
            web.evaluateJavaScript(request["js"] as? String ?? "document.title") { value, error in
                MainActor.assumeIsolated {
                    if let error { answer(["error": error.localizedDescription]); return }
                    answer(["value": Bench.plain(value)])
                }
            }
        case "ext-page":
            // One of the extension's own pages in a bench tab, where `eval`
            // runs with the extension's APIs.
            guard let id = request["id"] as? String, let context = extensions.contexts[id] else {
                answer(["error": "no such extension loaded"])
                return
            }
            let path = (request["path"] as? String ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let tab = browser.benchOpen(context.baseURL.appendingPathComponent(path))
            house(tab)
            answer(describe(tab))
        default:
            answer(["error": "unknown"])
        }
    }
}
#endif
