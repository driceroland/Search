import Foundation

/// An optional mark shown beside a tab group's name.
enum TabGroupIcon: Codable, Equatable {
    case symbol(String)
    case emoji(String)

    /// Make an emoji icon only when the text is one emoji character.
    static func emoji(from text: String) -> TabGroupIcon? {
        let icon = TabGroupIcon.emoji(text)
        return icon.validated
    }

    /// The value that may be saved and shown. This also keeps old or edited
    /// session files from introducing symbols outside the spaces icon set.
    var validated: TabGroupIcon? {
        switch self {
        case .symbol(let name):
            return Spaces.icons.contains(name) ? .symbol(name) : nil
        case .emoji(let text):
            return Self.isSingleEmoji(text) ? .emoji(text) : nil
        }
    }

    private static func isSingleEmoji(_ text: String) -> Bool {
        guard !text.isEmpty, text.count == 1 else { return false }
        let scalars = Array(text.unicodeScalars)
        let values = scalars.map(\.value)
        let regionalIndicators = values.filter { (0x1F1E6...0x1F1FF).contains($0) }
        // A flag is a pair of regional indicators. Lone indicators can look
        // like letters on some systems and aren't a complete flag.
        if !regionalIndicators.isEmpty,
           !(scalars.count == 2 && regionalIndicators.count == 2) { return false }

        let isKeycapBase: (UInt32) -> Bool = { value in
            value == 0x23 || value == 0x2A || (0x30...0x39).contains(value)
        }
        let keycapMark: UInt32 = 0x20E3
        let variationSelector: UInt32 = 0xFE0F
        let joiner: UInt32 = 0x200D
        let hasKeycap = values.contains(keycapMark)

        if hasKeycap {
            // A keycap is a digit, # or * with the enclosing mark, optionally
            // with VS16 between them.
            guard scalars.count == 2 || scalars.count == 3,
                  values.last == keycapMark,
                  let baseIndex = values.firstIndex(where: isKeycapBase),
                  baseIndex == 0,
                  values.dropFirst().dropLast().allSatisfy({ $0 == variationSelector }) else { return false }
            return true
        }
        // #, * and digits become emoji only as keycaps; VS16 alone does not
        // turn a number into an icon.
        guard !values.contains(where: isKeycapBase) else { return false }

        // Emoji tag flags are one black-flag scalar followed by tag letters,
        // digits or hyphens, and a cancel-tag scalar.
        let tagValues = values.dropFirst()
        let hasTagScalar = values.contains { (0xE0020...0xE007F).contains($0) }
        let validTagFlag = hasTagScalar
            && values.first == 0x1F3F4
            && values.last == 0xE007F
            && values.count >= 3
            && tagValues.dropLast().allSatisfy { (0xE0030...0xE0039).contains($0) || $0 == 0xE002D || (0xE0061...0xE007A).contains($0) }
        if hasTagScalar && !validTagFlag { return false }

        for index in scalars.indices {
            let value = values[index]
            if scalars[index].properties.isEmojiModifier {
                var before = index - 1
                while before >= 0, values[before] == variationSelector { before -= 1 }
                guard before >= 0, scalars[before].properties.isEmojiModifierBase else { return false }
                continue
            }
            if scalars[index].properties.isEmoji { continue }
            if value == variationSelector {
                guard index > 0, scalars[index - 1].properties.isEmoji else { return false }
                continue
            }
            if value == joiner {
                var before = index - 1
                while before >= 0, values[before] == variationSelector { before -= 1 }
                guard before >= 0, index + 1 < scalars.count,
                      scalars[before].properties.isEmoji,
                      scalars[index + 1].properties.isEmoji else { return false }
                continue
            }
            if validTagFlag, (0xE0020...0xE007F).contains(value) { continue }
            return false
        }

        // Emoji=Yes includes plain digits and a few text-only symbols. They
        // need an emoji presentation selector, unless they are a flag pair.
        let hasEmojiPresentation = scalars.contains { $0.properties.isEmojiPresentation }
        return hasEmojiPresentation || values.contains(variationSelector)
    }
}

/// A named section of ordinary tabs in one space's tab layout.
/// Its tabs remain ordinary tabs; their own group IDs describe membership.
struct TabGroup: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var collapsed: Bool
    var icon: TabGroupIcon? = nil
}

extension TabGroup {
    private enum Keys: String, CodingKey { case id, name, collapsed, icon }

    /// A group saved without its folded state is an open one.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        collapsed = (try? c.decodeIfPresent(Bool.self, forKey: .collapsed)) ?? false
        icon = (try? c.decode(TabGroupIcon.self, forKey: .icon))?.validated
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(collapsed, forKey: .collapsed)
        if let icon = icon?.validated {
            try c.encode(icon, forKey: .icon)
        }
    }
}

extension TabGroup {
    /// The number an extension knows the group by, as Chrome numbers its
    /// groups. Taken from the identifier, so it stays the same for as long
    /// as the group lasts, across launches too, with nothing to keep.
    static func number(_ id: UUID) -> Int {
        let u = id.uuid
        let n = Int(u.0 & 0x7F) << 24 | Int(u.1) << 16 | Int(u.2) << 8 | Int(u.3)
        return n == 0 ? 1 : n
    }
}
