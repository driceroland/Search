import Foundation

/// A file on this Mac that WebKit won't show for want of a type, and that is
/// text all the same: a Makefile, a dotfile, a .swift or a .log, which it
/// types as application/octet-stream and so hands to the downloads, where a
/// copy of a file already on disk lands in the Downloads folder.
enum LocalText {
    /// Anything bigger is left to the downloads rather than read whole.
    static let limit = 20 << 20

    /// The file's bytes when it is a regular file, not over `limit`, and
    /// reads as UTF-8 text: no NUL, nothing that isn't a letter. Binary, and
    /// text in another encoding, are not text here.
    static func contents(of file: URL, limit: Int = LocalText.limit) -> Data? {
        guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, let size = values.fileSize, size <= limit,
              let data = try? Data(contentsOf: file),
              !data.contains(0), String(data: data, encoding: .utf8) != nil
        else { return nil }
        return data
    }
}
