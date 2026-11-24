import AppKit
import UniformTypeIdentifiers
import WebKit

// Small pieces many DevTools panels share, kept in one place so each panel
// says what it wants rather than how AppKit and WebKit are driven.

/// The save and open panels DevTools' exports and imports show: as a sheet
/// on the key window, or modally when there is none.
@MainActor
enum DeveloperFilePanel {
    /// Shows `panel` and hands the chosen file on; nothing when cancelled.
    static func run(_ panel: NSSavePanel, then use: @escaping (URL) -> Void) {
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window) { response in
                if response == .OK, let url = panel.url { use(url) }
            }
        } else if panel.runModal() == .OK, let url = panel.url {
            use(url)
        }
    }

    /// A save panel named `name`, for `types`, that can make folders, with
    /// `accessory` (options) under the file name.
    static func save(name: String, types: [UTType], accessory: NSView? = nil, then use: @escaping (URL) -> Void) {
        let panel = NSSavePanel()
        panel.accessoryView = accessory
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = types
        panel.canCreateDirectories = true
        run(panel, then: use)
    }

    /// An open panel for one file of `types`.
    static func open(types: [UTType], then use: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = types
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        run(panel, then: use)
    }
}

@MainActor
extension WKUserContentController {
    /// Puts `script` in, unless it is in already, and has Tab.arm keep it
    /// at each navigation, as the tab's own scripts are.
    func developerArm(_ script: WKUserScript) {
        ArmedRiders.add(script, to: self)
        if !userScripts.contains(where: { $0 === script }) { addUserScript(script) }
    }

    /// Takes `script` out, if it is in. WebKit takes user scripts out all
    /// at once, so the others go back.
    func developerRemove(_ script: WKUserScript) {
        guard userScripts.contains(where: { $0 === script }) else { return }
        let others = userScripts.filter { $0 !== script }
        removeAllUserScripts()
        others.forEach(addUserScript)
    }
}
