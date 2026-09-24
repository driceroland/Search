import Foundation
import CryptoKit
import Security

// Chrome extensions, straight from the Chrome Web Store.
//
// An extension there is a .crx: a zip with a signed header in front of it.
// It is fetched from the same public update address every Chromium browser
// asks, the header is checked, and the zip is unpacked into the app's own
// folder for WebKit to load.
//
// The check that matters: a Chrome extension's id is not a name anybody
// chose — it is the first sixteen bytes of the SHA-256 of its public key,
// written as letters a to p. So the header must carry a public key that
// hashes to the id that was asked for, and a signature by that key over the
// zip that came with it. A file that was altered on the way, or an
// extension passed off under another's id, fails one or the other.

enum Crx {
    enum Refused: LocalizedError {
        case notAnID, download(Int), empty, notCrx, unsignedOrWrong, unpack

        var errorDescription: String? {
            switch self {
            case .notAnID: return "That isn't a Chrome Web Store link or extension id"
            case .download(let code): return "The Chrome Web Store answered \(code)"
            case .empty: return "The Chrome Web Store has nothing for that id — it may have been taken down, or only exist for old versions of Chrome"
            case .notCrx: return "What came back isn't a Chrome extension"
            case .unsignedOrWrong: return "The extension's signature doesn't hold up"
            case .unpack: return "The extension couldn't be unpacked"
            }
        }
    }

    /// The version of Chrome the store is told it is talking to. Some
    /// extensions set a minimum; the store refuses to hand those to a
    /// browser that says it is older.
    static let chromeVersion = "140.0.0.0"

    /// Thirty-two letters from a to p, wherever they are — a bare id, a store
    /// link, an old chrome.google.com/webstore link.
    static func id(in text: String) -> String? {
        let pattern = try! NSRegularExpression(pattern: "(?<![a-z])([a-p]{32})(?![a-z])")
        let range = NSRange(text.startIndex..., in: text)
        guard let match = pattern.firstMatch(in: text.lowercased(), range: range),
              let found = Range(match.range(at: 1), in: text)
        else { return nil }
        return text[found].lowercased()
    }

    static func downloadURL(for id: String) -> URL {
        var parts = URLComponents(string: "https://clients2.google.com/service/update2/crx")!
        parts.queryItems = [
            URLQueryItem(name: "response", value: "redirect"),
            URLQueryItem(name: "prodversion", value: chromeVersion),
            URLQueryItem(name: "acceptformat", value: "crx3"),
            URLQueryItem(name: "x", value: "id=\(id)&installsource=ondemand&uc"),
        ]
        return parts.url!
    }

    static func fetch(_ id: String) async throws -> Data {
        var request = URLRequest(url: downloadURL(for: id))
        request.timeoutInterval = 60
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw Refused.download(http.statusCode)
        }
        guard !data.isEmpty else { throw Refused.empty }
        return data
    }

    /// The zip inside a CRX3, once its signature has been checked against
    /// `id`.
    static func verifiedZip(_ crx: Data, id: String) throws -> Data {
        let bytes = [UInt8](crx)
        guard bytes.count > 12, Array(bytes[0..<4]) == Array("Cr24".utf8) else { throw Refused.notCrx }
        let version = le32(bytes, 4)
        guard version == 3 else { throw Refused.notCrx }
        let headerSize = Int(le32(bytes, 8))
        guard 12 + headerSize <= bytes.count else { throw Refused.notCrx }
        let header = Array(bytes[12..<(12 + headerSize)])
        let zip = Data(bytes[(12 + headerSize)...])

        // CrxFileHeader: 2 = sha256_with_rsa proofs, 3 = sha256_with_ecdsa
        // proofs, 10000 = signed_header_data (SignedData: 1 = crx_id).
        let fields = protobuf(header)
        guard let signedHeader = fields.first(where: { $0.0 == 10000 })?.1 else { throw Refused.unsignedOrWrong }
        guard let crxID = protobuf(signedHeader).first(where: { $0.0 == 1 })?.1,
              letters(crxID) == id
        else { throw Refused.unsignedOrWrong }

        // What is signed: a fixed prefix, the signed header, and the zip.
        var message = Data("CRX3 SignedData".utf8)
        message.append(0)
        var length = UInt32(signedHeader.count).littleEndian
        message.append(Data(bytes: &length, count: 4))
        message.append(Data(signedHeader))
        message.append(zip)

        // One RSA proof, whose key is the one the id is made from, and whose
        // signature holds over the message. The store adds a proof of its
        // own; that one is fine to hold too but is not the one that counts.
        let proofs = fields.filter { $0.0 == 2 }.map { protobuf($0.1) }
        let owns = proofs.contains { proof in
            guard let key = proof.first(where: { $0.0 == 1 })?.1,
                  let signature = proof.first(where: { $0.0 == 2 })?.1,
                  letters(Array(SHA256.hash(data: Data(key)).prefix(16))) == id
            else { return false }
            return verify(rsaSPKI: Data(key), signature: Data(signature), message: message)
        }
        guard owns else { throw Refused.unsignedOrWrong }
        return zip
    }

    /// Unpacks a zip into `folder`, which is replaced whole.
    static func unpack(_ zip: Data, into folder: URL) throws {
        let files = FileManager.default
        let scratch = files.temporaryDirectory.appendingPathComponent("search-crx-\(UUID().uuidString)")
        try files.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: scratch) }
        let archive = scratch.appendingPathComponent("x.zip")
        try zip.write(to: archive)
        let out = scratch.appendingPathComponent("out", isDirectory: true)
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", archive.path, out.path]
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0,
              files.fileExists(atPath: out.appendingPathComponent("manifest.json").path)
        else { throw Refused.unpack }
        // `ditto` keeps a symbolic link as a link, and the shim is installed
        // by rewriting the pages a package ships: a link among them would
        // have that rewrite land wherever it points. Nothing an extension
        // needs is a link, so one is refused whole.
        let carried = files.enumerator(at: out, includingPropertiesForKeys: [.isSymbolicLinkKey])
        while let item = carried?.nextObject() as? URL {
            guard (try? item.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true
            else { throw Refused.unpack }
        }
        try? files.removeItem(at: folder)
        try files.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
        try files.moveItem(at: out, to: folder)
    }

    // MARK: - pieces

    private static func le32(_ b: [UInt8], _ at: Int) -> UInt32 {
        UInt32(b[at]) | UInt32(b[at + 1]) << 8 | UInt32(b[at + 2]) << 16 | UInt32(b[at + 3]) << 24
    }

    /// The id's letters: each half-byte is a letter from a (0) to p (15).
    static func letters(_ bytes: [UInt8]) -> String {
        String(bytes.flatMap { [$0 >> 4, $0 & 0x0f] }.map { Character(UnicodeScalar(UInt8(97) + $0)) })
    }

    /// Length-delimited fields only, which is all a CRX header holds.
    private static func protobuf(_ b: [UInt8]) -> [(Int, [UInt8])] {
        var out: [(Int, [UInt8])] = []
        var i = 0
        func varint() -> Int? {
            var value = 0, shift = 0
            while i < b.count {
                let byte = Int(b[i]); i += 1
                value |= (byte & 0x7f) << shift
                if byte & 0x80 == 0 { return value }
                shift += 7
                if shift > 56 { return nil }
            }
            return nil
        }
        while i < b.count {
            guard let key = varint() else { break }
            let field = key >> 3, wire = key & 7
            switch wire {
            case 2:
                guard let length = varint(), i + length <= b.count else { return out }
                out.append((field, Array(b[i..<(i + length)])))
                i += length
            case 0: _ = varint()
            case 1: i += 8
            case 5: i += 4
            default: return out
            }
        }
        return out
    }

    /// An RSA public key as Chrome writes it (SubjectPublicKeyInfo DER),
    /// checked against a PKCS#1 v1.5 SHA-256 signature.
    private static func verify(rsaSPKI: Data, signature: Data, message: Data) -> Bool {
        var format = SecExternalFormat.formatOpenSSL
        var type = SecExternalItemType.itemTypePublicKey
        var items: CFArray?
        guard SecItemImport(rsaSPKI as CFData, nil, &format, &type, [], nil, nil, &items) == errSecSuccess,
              let key = (items as? [Any])?.first
        else { return false }
        return SecKeyVerifySignature(
            key as! SecKey, .rsaSignatureMessagePKCS1v15SHA256,
            message as CFData, signature as CFData, nil
        )
    }
}
