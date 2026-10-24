import SwiftUI

/// The accounts kept for a site, hanging from the sign-in box the caret is
/// in. The same white and hairline as everything else that floats over a
/// page; one line per account, the name in ink and the site under it in
/// grey; a click puts both into the form. The Mac's passkeys for a page
/// waiting for one come first, as in Safari; a click on one brings up the
/// Mac's sheet for it. It follows the box when the page scrolls, and goes
/// when the caret does.
struct AccountList: View {
    @ObservedObject var browser: Browser
    let asked: Browser.Suggesting
    /// Where the card came out in its host, for a host that has to know
    /// where it is to keep a click on it (see PaneStage's AccountHost).
    var onFrame: ((CGRect) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(asked.passkeys) { passkey in
                Row(mark: .symbol("person.badge.key"), name: passkey.name,
                    detail: "Passkey" + (passkey.provider.map { " · \($0)" } ?? "")) { browser.choose(passkey) }
            }
            ForEach(asked.logins) { login in
                Row(mark: .letter(login.user.first.map { String($0).uppercased() } ?? "•"),
                    name: login.user.isEmpty ? "No name" : login.user, detail: login.host) { browser.choose(login) }
            }
            // The Mac's Passwords app, when turned on (ApplePasswords.swift):
            // after Search's own, marked as Apple's.
            ForEach(asked.apple) { login in
                Row(mark: .letter(login.user.first.map { String($0).uppercased() } ?? "•"),
                    name: login.user.isEmpty ? "No name" : login.user, detail: "Apple Passwords") { browser.choose(login) }
            }
            if asked.appleConnect {
                Row(mark: .symbol("key.icloud"), name: "Connect Apple Passwords…",
                    detail: "Pair once with a code from your Mac") { browser.connectApplePasswords() }
            }
            HStack(spacing: 6) {
                Image(systemName: "key")
                    .font(.system(size: 9, weight: .medium))
                Text(footer)
                    .font(.system(size: 10.5))
                Spacer(minLength: 0)
            }
            .foregroundStyle(Palette.faint)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Palette.wash.opacity(0.5))
        }
        .frame(width: max(240, min(360, asked.spot.width)), alignment: .leading)
        .background(Palette.ground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Palette.hairline, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.14), radius: 22, y: 8)
        // Measured inside the offset, so where it is drawn, not laid out.
        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named(FromTopLeft<AccountList>.space)) }) { onFrame?($0) }
        // Just under the box, left edges lined up. The offset is from the
        // stage's top-left, which is also the web view's.
        .offset(x: asked.spot.minX, y: asked.spot.maxY + 6)
    }

    private var footer: String {
        if asked.logins.isEmpty && asked.apple.isEmpty && !asked.appleConnect { return "Passkeys on this Mac" }
        if asked.logins.isEmpty { return "From Apple Passwords" }
        return asked.apple.isEmpty ? "From your keychain" : "From your keychain and Apple Passwords"
    }

    private enum Mark { case letter(String), symbol(String) }

    private struct Row: View {
        let mark: Mark
        let name: String
        let detail: String
        let pick: () -> Void
        @State private var hovering = false

        var body: some View {
            Button(action: pick) {
                HStack(spacing: 10) {
                    Group {
                        switch mark {
                        case .letter(let letter): Text(letter).font(.system(size: 11, weight: .medium))
                        case .symbol(let name): Image(systemName: name).font(.system(size: 10, weight: .medium))
                        }
                    }
                    .foregroundStyle(Palette.ink)
                    .frame(width: 22, height: 22)
                    .background(Palette.wash, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(name)
                            .font(.system(size: 12.5))
                            .foregroundStyle(Palette.ink)
                            .lineLimit(1)
                        Text(detail)
                            .font(.system(size: 10.5))
                            .foregroundStyle(Palette.muted)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(hovering ? Palette.hover : .clear)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .animation(Motion.quick, value: hovering)
        }
    }
}
