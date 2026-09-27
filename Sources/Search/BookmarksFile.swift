import Foundation

// A bookmarks file, as every browser exports one: Chrome, Safari, Firefox,
// Arc and the rest all write the same old Netscape format, an HTML page of
// nested lists. It is the one way in from a browser Search can't read
// directly, or from another Mac.
//
//     <DT><H3>Folder</H3>
//     <DL><p>
//         <DT><A HREF="https://example.com/">Example</A>
//     </DL><p>
//
// Read loosely, as browsers write it loosely: tags in any case, paragraphs
// and closing tags left out, attributes in any order. Only http and https
// addresses are kept, as the other imports do.

enum BookmarksFile {
    /// The file's bookmarks, folders and all; nil for a file that isn't one.
    static func read(_ url: URL) -> [Bookmark]? {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1),
              text.range(of: "<DL", options: .caseInsensitive) != nil
        else { return nil }
        return parse(text)
    }

    static func parse(_ text: String) -> [Bookmark] {
        // One pass over the tags that matter. A folder's heading is kept
        // until its list opens; a list that closes hands its pages to the
        // folder that holds it.
        let pattern = #"<(H3|A)\b([^>]*)>(.*?)</\1\s*>|<(/?)DL\b[^>]*>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return [] }
        let ns = text as NSString

        var stack: [(title: String?, nodes: [Bookmark])] = []
        var root: [Bookmark] = []
        var heading: String?
        // The bookmarks bar, as Chrome and Firefox mark it: its pages go to
        // the top, as bringing Chrome's in directly puts them.
        var bar = false

        func append(_ node: Bookmark) {
            if stack.isEmpty { root.append(node) } else { stack[stack.count - 1].nodes.append(node) }
        }

        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            if match.range(at: 1).location != NSNotFound {
                let tag = ns.substring(with: match.range(at: 1)).uppercased()
                let attributes = ns.substring(with: match.range(at: 2))
                let title = clean(ns.substring(with: match.range(at: 3)))
                if tag == "H3" {
                    heading = title
                    bar = attribute("PERSONAL_TOOLBAR_FOLDER", in: attributes)?.lowercased() == "true"
                } else if let href = attribute("HREF", in: attributes), let url = URL(string: href),
                          url.scheme == "http" || url.scheme == "https" {
                    append(.site(title.isEmpty ? (url.host() ?? href) : title, url))
                }
            } else if ns.substring(with: match.range(at: 4)).isEmpty {
                // <DL>: the list of the folder just named — or, the first
                // time, of the file itself. Past a depth no one files at,
                // a list's pages join the folder that holds it, so a file
                // nested without end can't be too deep to keep.
                if stack.count >= 64 {
                    stack.append((nil, []))
                } else if heading == nil, stack.isEmpty, root.isEmpty {
                    stack.append((nil, []))
                } else if bar, stack.count <= 1 {
                    stack.append((nil, []))
                } else {
                    stack.append((heading ?? "Folder", []))
                }
                heading = nil
                bar = false
            } else if let list = stack.popLast() {
                // </DL>
                if let title = list.title { append(.folder(title, list.nodes)) } else if stack.isEmpty { root += list.nodes } else { stack[stack.count - 1].nodes += list.nodes }
            }
        }
        // A file cut short: what was open still counts.
        while let list = stack.popLast() {
            if let title = list.title { append(.folder(title, list.nodes)) } else if stack.isEmpty { root += list.nodes } else { stack[stack.count - 1].nodes += list.nodes }
        }
        return root
    }

    private static func attribute(_ name: String, in text: String) -> String? {
        let pattern = name + #"\s*=\s*("([^"]*)"|'([^']*)'|([^\s>]+))"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        for group in 2...4 where match.range(at: group).location != NSNotFound {
            return decode(ns.substring(with: match.range(at: group)))
        }
        return nil
    }

    /// A title without any markup left in it, its entities decoded.
    private static func clean(_ text: String) -> String {
        let bare = text.replacingOccurrences(of: #"<[^>]*>"#, with: "", options: .regularExpression)
        return decode(bare).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decode(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var out = text
        for (entity, character) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&nbsp;", " ")] {
            out = out.replacingOccurrences(of: entity, with: character, options: .caseInsensitive)
        }
        // Numbered ones, then the ampersand itself last, so "&amp;lt;" stays "&lt;".
        if let regex = try? NSRegularExpression(pattern: #"&#(x?)([0-9a-fA-F]+);"#) {
            let ns = out as NSString
            for match in regex.matches(in: out, range: NSRange(location: 0, length: ns.length)).reversed() {
                let hex = ns.substring(with: match.range(at: 1)) == "x"
                let digits = ns.substring(with: match.range(at: 2))
                if let code = UInt32(digits, radix: hex ? 16 : 10), let scalar = Unicode.Scalar(code) {
                    out = (out as NSString).replacingCharacters(in: match.range, with: String(Character(scalar)))
                }
            }
        }
        return out.replacingOccurrences(of: "&amp;", with: "&", options: .caseInsensitive)
    }
}
