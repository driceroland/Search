import SwiftUI

/// The accounts kept for a site, hanging from the sign-in box the caret is
/// in. The same white and hairline as everything else that floats over a
/// page; one line per account, the name in ink and the site under it in
/// grey; a click puts both into the form. The Mac's passkeys for a page
/// waiting for one come first, as in Safari; a click on one brings up the
/// Mac's sheet for it. Under a box for your name, email, phone or address,
/// your card in Contacts, and a click fills the form. ↓ and ↑ light a row
/// from the keyboard and Return takes it, as a click (App.swift's `take`).
/// It follows the box when the page scrolls, and goes when the caret does.
/// Many accounts for one site (#1215): the list is no taller than the room
/// under the box, or above it when there is more room there, and scrolls;
/// a row lit from the keyboard is scrolled to.
struct AccountList: View {
    @ObservedObject var browser: Browser
    let asked: Browser.Suggesting
    /// Where the card came out in its host, for a host that has to know
    /// where it is to keep a click on it (see PaneStage's AccountHost).
    var onFrame: ((CGRect) -> Void)? = nil
    /// How far below the top of its host the page starts (a small window's
    /// bar): the box's spot is from the page's top-left.
    var top: CGFloat = 0

    /// Kept clear between the list and the host's edge.
    static let margin: CGFloat = 8
    /// Less room than this under the box, and more above it: the list goes
    /// above. Never shorter than this either, if the page is that small.
    static let least: CGFloat = 140

    /// Where the list goes for a box at `spot` on a page `height` tall:
    /// under it or above it, and how tall it may be.
    nonisolated static func place(spot: CGRect, height: CGFloat) -> (up: Bool, room: CGFloat) {
        let below = height - spot.maxY - 6 - margin
        let above = spot.minY - 6 - margin
        let up = below < least && above > below
        return (up, max(up ? above : below, least))
    }

    var body: some View {
        GeometryReader { space in
            let spot = asked.spot.offsetBy(dx: 0, dy: top)
            let place = Self.place(spot: spot, height: space.size.height)
            card(room: place.room)
                // Measured inside the offset, so where it is drawn, not laid out.
                .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named(FromTopLeft<AccountList>.space)) }) { onFrame?($0) }
                // Above the box: its foot 6 points over the box's top.
                .frame(height: place.up ? max(0, spot.minY - 6) : nil, alignment: .bottom)
                // Just under the box (or over it), left edges lined up. The
                // offset is from the stage's top-left, which is also the web view's.
                .offset(x: spot.minX, y: place.up ? 0 : spot.maxY + 6)
        }
    }

    private func card(room: CGFloat) -> some View {
        Capped(room: room) {
        VStack(alignment: .leading, spacing: 0) {
            // As tall as the rows when they fit; otherwise they scroll under
            // a footer that stays.
            ScrollViewReader { scroller in
                ViewThatFits(in: .vertical) {
                    rows(marked: false)
                    ScrollView(.vertical) { rows(marked: true) }
                        .scrollIndicators(.automatic)
                }
                .onChange(of: asked.lit) { _, lit in
                    guard let lit else { return }
                    scroller.scrollTo(lit)
                }
            }
            if !offerOnly {
            HStack(spacing: 6) {
                Image(systemName: contactsOnly ? "person.crop.rectangle" : "key")
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
        }
        .frame(width: max(240, min(360, asked.spot.width)), alignment: .leading)
        }
        .background(Palette.ground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Palette.hairline, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.14), radius: 22, y: 8)
    }

    /// The rows in the order ↓ walks them (Suggesting.choices): the Mac's
    /// passkeys, the page's own host's accounts from both places, then the
    /// rest of its site's under a line, so a login saved for example.com is
    /// still there on admin.example.com without passing for admin's; codes,
    /// the rows about Apple Passwords, your card.
    /// `marked`: each row carries its number, for the scroller to find; only
    /// in the one that scrolls, so it never looks in the other.
    private func rows(marked: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            let choices = asked.choices
            ForEach(Array(choices.enumerated()), id: \.offset) { at, choice in
                if at == asked.othersFrom {
                    Text("Other accounts on \(Vault.registrable(asked.host))")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Palette.faint)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .overlay(alignment: .top) { Rectangle().fill(Palette.hairline).frame(height: 1) }
                }
                if marked { row(choice, lit: asked.lit == at).id(at) } else { row(choice, lit: asked.lit == at) }
            }
        }
    }

    @ViewBuilder
    private func row(_ choice: Browser.Suggesting.Choice, lit: Bool) -> some View {
        switch choice {
        case .passkey(let passkey):
            Row(mark: .symbol("person.badge.key"), name: passkey.name,
                detail: "Passkey" + (passkey.provider.map { " · \($0)" } ?? ""), lit: lit) { browser.choose(passkey) }
        case .login(let login):
            Row(mark: .letter(login.user.first.map { String($0).uppercased() } ?? "•"),
                name: login.user.isEmpty ? "No name" : login.user, detail: login.host, lit: lit) { browser.choose(login) }
        case .apple(let login):
            // The Mac's Passwords app, when turned on (ApplePasswords.swift):
            // marked as Apple's.
            Row(mark: .letter(login.user.first.map { String($0).uppercased() } ?? "•"),
                name: login.user.isEmpty ? "No name" : login.user, detail: "Apple Passwords", lit: lit) { browser.choose(login) }
        case .code(let code):
            Row(mark: .symbol("number"), name: code.user.isEmpty ? "Verification code" : code.user,
                detail: code.user.isEmpty ? "Apple Passwords" : "Verification code · Apple Passwords", lit: lit) { browser.choose(code) }
        case .connect:
            Row(mark: .symbol("key.icloud"), name: "Connect Apple Passwords…",
                detail: "Pair once with a code from your Mac", lit: lit) { browser.connectApplePasswords() }
        case .offer:
            OfferRow(lit: lit, use: browser.useApplePasswords, never: browser.neverOfferApplePasswords)
        case .contact(let contact):
            // A click fills the form; a shift-click, the box alone.
            Row(mark: .symbol("person.crop.circle"), name: contact.title, detail: contact.detail, lit: lit) {
                browser.choose(contact, alone: NSEvent.modifierFlags.contains(.shift))
            }
            .help("Fills the form. Shift-click fills only this box.")
        }
    }

    /// Nothing but the offer: no footer under it, the row says it all.
    private var offerOnly: Bool {
        asked.appleOffer != nil && asked.logins.isEmpty && asked.passkeys.isEmpty && asked.apple.isEmpty && asked.codes.isEmpty && !asked.appleConnect
            && asked.contacts.isEmpty
    }

    /// Nothing but your card's rows.
    private var contactsOnly: Bool {
        !asked.contacts.isEmpty && asked.logins.isEmpty && asked.passkeys.isEmpty && asked.apple.isEmpty && asked.codes.isEmpty
            && !asked.appleConnect
    }

    private var footer: String {
        if contactsOnly { return "From your card in Contacts" }
        if asked.logins.isEmpty && asked.apple.isEmpty && asked.codes.isEmpty && !asked.appleConnect { return "Passkeys on this Mac" }
        if asked.logins.isEmpty { return "From Apple Passwords" }
        return asked.apple.isEmpty ? "From your keychain" : "From your keychain and Apple Passwords"
    }

    private enum Mark { case letter(String), symbol(String) }

    /// Offers its content no more than `room` and is as tall as the content
    /// then is: a short list keeps its own height, a long one stops at
    /// `room` (where its rows scroll). `.frame(maxHeight:)` would make the
    /// short one `room` tall too.
    private struct Capped: Layout {
        let room: CGFloat

        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            guard let only = subviews.first else { return .zero }
            let size = only.sizeThatFits(ProposedViewSize(width: proposal.width, height: room))
            return CGSize(width: size.width, height: min(size.height, room))
        }

        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
            subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(bounds.size))
        }
    }

    /// "Use your Apple passwords?", at the bottom: smaller and greyer than
    /// an account, so it never reads as one. A click turns Apple Passwords
    /// on and pairs; the ✕ says don't offer again.
    struct OfferRow: View {
        /// Come to with ↓ and ↑: Return takes it, as a click on it.
        var lit = false
        let use: () -> Void
        let never: () -> Void
        @State private var hovering = false
        @State private var onCross = false

        var body: some View {
            HStack(spacing: 8) {
                Button(action: use) {
                    HStack(spacing: 8) {
                        Image(systemName: "key")
                            .font(.system(size: 9, weight: .medium))
                            .frame(width: 22)
                        Text("Use your Apple passwords?")
                            .font(.system(size: 11.5))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle((hovering && !onCross) || lit ? Palette.ink : Palette.muted)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Turns on Apple Passwords and pairs with a code from your Mac. Settings › Passwords turns it off.")
                Button(action: never) {
                    Image(systemName: "xmark")
                        .font(.system(size: 7.5, weight: .semibold))
                        .foregroundStyle(Palette.faint)
                        .frame(width: 16, height: 16)
                        .background(Palette.ink.opacity(onCross ? 0.07 : 0), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .onHover { onCross = $0 }
                .help("Don't offer again")
                .accessibilityLabel("Don't offer again")
            }
            .padding(.leading, 10)
            .padding(.trailing, 8)
            .padding(.vertical, 6)
            .background(hovering || lit ? Palette.hover : .clear)
            .onHover { hovering = $0 }
            .animation(Motion.quick, value: hovering)
            .animation(Motion.quick, value: onCross)
        }
    }

    private struct Row: View {
        let mark: Mark
        let name: String
        let detail: String
        /// Come to with ↓ and ↑: lit as under the pointer.
        var lit = false
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
                .background(hovering || lit ? Palette.hover : .clear)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .animation(Motion.quick, value: hovering)
        }
    }
}

extension Browser.Suggesting {
    /// One row of the list, which a click or Return on it picks.
    enum Choice: Equatable {
        case passkey(Passkeys.Offered)
        case login(Kept)
        case apple(AppleLogin)
        case code(AppleCode)
        /// "Connect Apple Passwords…"
        case connect
        /// "Use your Apple passwords?"
        case offer
        case contact(MeCard.Offer)
    }

    /// The rows top to bottom, as drawn and as ↓ walks them.
    var choices: [Choice] {
        passkeys.map(Choice.passkey) + ownLogins.map(Choice.login) + ownApple.map(Choice.apple)
            + siteLogins.map(Choice.login) + siteApple.map(Choice.apple) + codes.map(Choice.code)
            + (appleConnect ? [.connect] : []) + (appleOffer != nil ? [.offer] : []) + contacts.map(Choice.contact)
    }

    /// Where "Other accounts on …" goes, before the first of the rest of the
    /// site's accounts: only when this host has some of its own above them.
    var othersFrom: Int? {
        guard !(ownLogins.isEmpty && ownApple.isEmpty), !(siteLogins.isEmpty && siteApple.isEmpty) else { return nil }
        return passkeys.count + ownLogins.count + ownApple.count
    }

    private var ownLogins: [Kept] { logins.filter { Vault.belongs($0.host, to: host, wide: false) } }
    private var siteLogins: [Kept] { logins.filter { !Vault.belongs($0.host, to: host, wide: false) } }
    private var ownApple: [AppleLogin] { apple.filter { owns($0) } }
    private var siteApple: [AppleLogin] { apple.filter { !owns($0) } }

    private func owns(_ login: AppleLogin) -> Bool {
        appleHost.map { ApplePasswords.belongs(login.sites, to: $0, wide: false) } ?? false
    }
}
