import AppKit
import WebKit
import NaturalLanguage
import UserNotifications
import IOKit.pwr_mgt

// The Mac and the browser's own settings: fonts, language, notifications, speech, power, identity.
// Part of the Chrome APIs Shy answers itself (ExtensionShims.answer); each case
// is one call, and a call this part does not know is left for the others.

@available(macOS 15.4, *)
@MainActor
extension ExtensionShims {
    static func runSystem(_ api: String, _ args: [Any], _ context: WKWebExtensionContext, _ owner: Extensions, _ browser: Browser) async throws -> Any? {
        let first = args.first
        let id = context.uniqueIdentifier
        switch api {
        // MARK: fonts — what the Mac has; the page's own fonts stay the page's
        case "fontSettings.getFontList":
            return NSFontManager.shared.availableFontFamilies.map { ["fontId": $0, "displayName": $0] }
        case "fontSettings.getFont":
            return ["fontId": "", "levelOfControl": "not_controllable"]
        case "fontSettings.getDefaultFontSize":
            return ["pixelSize": 16, "levelOfControl": "not_controllable"]
        case "fontSettings.getDefaultFixedFontSize":
            return ["pixelSize": 13, "levelOfControl": "not_controllable"]
        case "fontSettings.getMinimumFontSize":
            return ["pixelSize": 0, "levelOfControl": "not_controllable"]
        case _ where api.hasPrefix("fontSettings.set") || api.hasPrefix("fontSettings.clear"):
            return nil

        // MARK: management — only itself
        case "management.getSelf", "management.get":
            let found = context.webExtension
            return ["id": id, "name": found.displayName ?? "", "shortName": found.displayShortName ?? "",
                    "version": found.version ?? "", "description": found.displayDescription ?? "",
                    "enabled": true, "type": "extension", "installType": owner.installed.first { $0.id == id }?.fromStore == false ? "development" : "normal",
                    "mayDisable": true, "offlineEnabled": true, "isApp": false, "hostPermissions": [], "permissions": []]
        case "management.getAll":
            return []
        case "management.setEnabled", "management.uninstallSelf":
            throw Unsupported(what: "Extensions are turned on and off in Settings › Extensions")

        // MARK: language
        case "i18n.detectLanguage":
            let recognizer = NLLanguageRecognizer()
            recognizer.processString(first as? String ?? "")
            let guesses = recognizer.languageHypotheses(withMaximum: 3)
            return ["isReliable": (guesses.values.max() ?? 0) > 0.6,
                    "languages": guesses.sorted { $0.value > $1.value }.map { ["language": $0.key.rawValue, "percentage": Int($0.value * 100)] }]
        case "runtime.getContexts":
            // The extension's own pages that Chrome would list: its worker,
            // its popup while it is up, its offscreen document. Bitwarden
            // asks for these to know where to send its messages.
            let filter = first as? [String: Any] ?? [:]
            let types = filter["contextTypes"] as? [String]
            let urls = filter["documentUrls"] as? [String]
            var found: [[String: Any]] = []
            func add(_ type: String, _ url: URL?) {
                guard types == nil || types!.contains(type) else { return }
                let address = url?.absoluteString ?? ""
                guard urls == nil || urls!.contains(address) else { return }
                found.append([
                    "contextType": type, "contextId": "\(id)-\(type)", "tabId": -1, "windowId": -1,
                    "frameId": type == "BACKGROUND" ? -1 : 0, "documentUrl": address,
                    "documentOrigin": url.map { "\($0.scheme ?? "")://\($0.host ?? "")" } ?? "",
                    "incognito": false,
                ])
            }
            if context.webExtension.hasBackgroundContent {
                let manifest = context.webExtension.manifest["background"] as? [String: Any] ?? [:]
                let script = manifest["service_worker"] as? String ?? manifest["page"] as? String
                add("BACKGROUND", script.map { context.baseURL.appendingPathComponent($0) })
            }
            if ExtensionPopup.shared.extensionID == id { add("POPUP", ExtensionPopup.shared.view?.url) }
            found += ExtensionOffscreen.contexts(for: id, matching: filter)
            return found

        // MARK: notifications — the Mac's own
        case "notifications.create":
            let named = first as? String
            let options = (named == nil ? first : (args.count > 1 ? args[1] : nil)) as? [String: Any] ?? [:]
            let key = named ?? UUID().uuidString
            let center = UNUserNotificationCenter.current()
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
            let content = UNMutableNotificationContent()
            content.title = options["title"] as? String ?? (context.webExtension.displayName ?? "")
            content.body = options["message"] as? String ?? ""
            content.subtitle = context.webExtension.displayName ?? ""
            try? await center.add(UNNotificationRequest(identifier: "\(id).\(key)", content: content, trigger: nil))
            return key
        case "notifications.clear":
            if let key = first as? String {
                UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["\(id).\(key)"])
            }
            return true
        case "notifications.getAll":
            return [String: Any]()
        case "notifications.getPermissionLevel":
            return "granted"
        case "notifications.update":
            return false

        // MARK: speech
        case "tts.speak":
            let options = (args.count > 1 ? args[1] : nil) as? [String: Any] ?? [:]
            if !(options["enqueue"] as? Bool ?? false) { speaker.stopSpeaking() }
            if let voice = options["voiceName"] as? String,
               let match = NSSpeechSynthesizer.availableVoices.first(where: { NSSpeechSynthesizer.attributes(forVoice: $0)[.name] as? String == voice }) {
                speaker.setVoice(match)
            }
            if let rate = options["rate"] as? Double { speaker.rate = Swift.Float(180 * rate) }
            speaker.startSpeaking(first as? String ?? "")
            return nil
        case "tts.stop":
            speaker.stopSpeaking()
            return nil
        case "tts.pause":
            speaker.pauseSpeaking(at: .immediateBoundary)
            return nil
        case "tts.resume":
            speaker.continueSpeaking()
            return nil
        case "tts.isSpeaking":
            return speaker.isSpeaking
        case "tts.getVoices":
            return NSSpeechSynthesizer.availableVoices.map { voice -> [String: Any] in
                let attributes = NSSpeechSynthesizer.attributes(forVoice: voice)
                return ["voiceName": attributes[.name] as? String ?? voice.rawValue,
                        "lang": (attributes[.localeIdentifier] as? String ?? "").replacingOccurrences(of: "_", with: "-"),
                        "remote": false, "eventTypes": ["start", "end"]]
            }

        // MARK: idle
        case "idle.queryState":
            let threshold = (first as? Double) ?? 60
            if let session = CGSessionCopyCurrentDictionary() as? [String: Any],
               session["CGSSessionScreenIsLocked"] as? Bool == true { return "locked" }
            let quiet = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
            return quiet >= threshold ? "idle" : "active"
        case "idle.getAutoLockDelay":
            return 0

        // MARK: power
        case "power.requestKeepAwake":
            let display = (first as? String) == "display"
            if let old = awake[id] { IOPMAssertionRelease(old) }
            var assertion: IOPMAssertionID = 0
            let kind = (display ? kIOPMAssertionTypePreventUserIdleDisplaySleep : kIOPMAssertionTypePreventUserIdleSystemSleep) as CFString
            if IOPMAssertionCreateWithName(kind, IOPMAssertionLevel(kIOPMAssertionLevelOn), "An extension in Shy" as CFString, &assertion) == kIOReturnSuccess {
                awake[id] = assertion
            }
            return nil
        case "power.releaseKeepAwake":
            if let old = awake.removeValue(forKey: id) { IOPMAssertionRelease(old) }
            return nil
        case "power.reportActivity":
            var assertion: IOPMAssertionID = 0
            IOPMAssertionDeclareUserActivity("An extension in Shy" as CFString, kIOPMUserActiveLocal, &assertion)
            return nil

        // MARK: system
        case "system.cpu.getInfo":
            #if arch(x86_64)
            let (arch, model) = ("x86_64", "Intel")
            #else
            let (arch, model) = ("arm64", "Apple silicon")
            #endif
            return ["numOfProcessors": ProcessInfo.processInfo.processorCount, "archName": arch,
                    "modelName": model, "features": [], "processors": [], "temperatures": []]
        case "system.memory.getInfo":
            return ["capacity": Double(ProcessInfo.processInfo.physicalMemory), "availableCapacity": Double(ProcessInfo.processInfo.physicalMemory) / 2]
        case "system.storage.getInfo":
            return []
        case "system.display.getInfo":
            return NSScreen.screens.enumerated().map { index, screen in
                let f = screen.frame, v = screen.visibleFrame
                return ["id": String(index), "name": screen.localizedName, "isPrimary": index == 0, "isInternal": index == 0,
                        "isEnabled": true, "dpiX": 96 * screen.backingScaleFactor, "dpiY": 96 * screen.backingScaleFactor,
                        "rotation": 0, "bounds": ["left": f.minX, "top": f.minY, "width": f.width, "height": f.height],
                        "workArea": ["left": v.minX, "top": v.minY, "width": v.width, "height": v.height]] as [String: Any]
            }

        // MARK: identity
        case "identity.launchWebAuthFlow":
            let spec = first as? [String: Any] ?? [:]
            guard let url = (spec["url"] as? String).flatMap(URL.init(string:)) else { throw Unsupported(what: "No authorization url") }
            // As in Chrome, a flow is non-interactive unless it says otherwise:
            // run out of sight, it either comes straight back or fails.
            if spec["interactive"] as? Bool != true {
                let wait = (spec["timeoutMsForNonInteractive"] as? NSNumber).map { $0.doubleValue / 1000 }
                return try await ExtensionAuth.quietly(url, extension: id, store: Spaces.store(for: browser.spaceID),
                                                       abortOnLoad: spec["abortOnLoadForNonInteractive"] as? Bool ?? true,
                                                       timeout: wait).absoluteString
            }
            return try await ExtensionAuth.run(url, extension: id, browser: browser).absoluteString
        case "identity.getProfileUserInfo":
            return ["email": "", "id": ""]
        case "identity.removeCachedAuthToken", "identity.clearAllCachedAuthTokens":
            return nil
        case "identity.getAuthToken":
            throw Unsupported(what: "getAuthToken needs a Google account signed into Chrome; this extension would need launchWebAuthFlow instead")

        default:
            return Unhandled()
        }
    }
}
