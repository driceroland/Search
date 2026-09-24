import CWebKitGTK
import Foundation

// The ad blocker, as on the Mac: the rules in ShieldRules, compiled once by
// WebKit and enforced in its networking before a request is made. WebKitGTK
// reads the same content blocker JSON Safari does; the compiled list is kept
// in the browser's folder, so the next launch only has to look it up.

enum Shield {
    static func protect(_ content: OpaquePointer?) {
        guard let json = ShieldRules.json() else { return }
        let path = Folder.file("shield").path
        guard let store = webkit_user_content_filter_store_new(path) else { return }
        let bytes = json.withCString { g_bytes_new($0, gsize(strlen($0))) }

        // The content manager outlives the compile: it belongs to the window.
        let saved: GAsyncReadyCallback = { source, result, data in
            var error: UnsafeMutablePointer<GError>?
            let filter = webkit_user_content_filter_store_save_finish(OpaquePointer(source), result, &error)
            if let filter {
                webkit_user_content_manager_add_filter(OpaquePointer(data), filter)
                webkit_user_content_filter_unref(filter)
            } else {
                let message = error.map { String(cString: $0.pointee.message) } ?? "unknown"
                FileHandle.standardError.write(Data("search: the block list didn't compile: \(message)\n".utf8))
                g_error_free(error)
            }
            g_object_unref(source)
        }
        webkit_user_content_filter_store_save(store, "office-shield", bytes, nil, saved, raw(content))
        g_bytes_unref(bytes)
    }
}
