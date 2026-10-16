import Foundation

/// A file on this Mac that reads as text, whatever its name says (#525).
/// Only a `file:` address, only a regular file, only up to a few megabytes,
/// and only when it is UTF-8 with no NUL in it — anything else, a picture or
/// an archive with no type WebKit knows, is still downloaded.
enum LocalText {
    static let largest = 5 << 20

    static func contents(of url: URL) -> Data? {
        guard url.isFileURL,
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, let size = values.fileSize, size <= largest,
              let data = try? Data(contentsOf: url, options: .mappedIfSafe)
        else { return nil }
        return isText(data) ? data : nil
    }

    static func isText(_ data: Data) -> Bool {
        guard !data.contains(0) else { return false }
        return String(data: data, encoding: .utf8) != nil
    }
}
