import SwiftUI

/// Every password kept, by site. The same white-and-hairline panel as the
/// rest, and the same rule: a password is never shown until you have proved
/// you are you, and never for longer than it takes to read it.
struct PasswordsPanel: View {
    @ObservedObject var browser: Browser

    @FocusState private var hunting: Bool
    @State private var open: String?
    @State private var adding = false
    @State private var importing: String?

    var body: some View {
        Plate("Passwords", width: 620, close: { browser.managing = false }) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Hunt(text: $browser.hunting, prompt: "Search sites and accounts", focus: $hunting)
                    Pill(adding ? "Cancel" : "Add", filled: !adding) { adding.toggle() }
                }

                if adding {
                    Card { AddForm(browser: browser) { adding = false } }
                        .transition(.opacity)
                }

                if browser.shownSites.isEmpty {
                    Card {
                        Nothing(browser.saved.isEmpty
                                ? "Nothing kept yet. Sign in somewhere and say yes, or bring yours in below."
                                : "Nothing matches.")
                    }
                } else {
                    ScrollView(showsIndicators: false) {
                        Card {
                            ForEach(Array(browser.shownSites.enumerated()), id: \.element.host) { index, site in
                                if index > 0 { Rule() }
                                Site(
                                    host: site.host,
                                    logins: site.logins,
                                    open: open == site.host,
                                    toggle: { open = open == site.host ? nil : site.host },
                                    copy: { browser.copy($0) },
                                    forget: { browser.forget($0) }
                                )
                            }
                        }
                        .padding(.bottom, 2)
                    }
                    .frame(maxHeight: 400)
                }
            }
        } foot: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text("Bring in from")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.muted)
                    // Only the browsers actually on this Mac.
                    ForEach(Chromium.installed()) { source in
                        Pill(source.name) {
                            importing = source.name
                            // Off the main thread: four hundred passwords is a
                            // moment of arithmetic, and the panel stays alive.
                            DispatchQueue.global(qos: .userInitiated).async {
                                let outcome = Result { try Chromium.read(source) }
                                DispatchQueue.main.async {
                                    importing = nil
                                    browser.took(outcome, from: source)
                                }
                            }
                        }
                        .disabled(importing != nil)
                    }
                    Pill("CSV file…") { browser.importPasswords() }
                        .disabled(importing != nil)
                    Spacer(minLength: 0)
                    if let importing {
                        Ring(size: 10)
                        Text("Reading \(importing)…")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Palette.muted)
                    } else {
                        Text(browser.saved.count == 1 ? "1 password" : "\(browser.saved.count) passwords")
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.muted)
                    }
                }
                Text("macOS asks once for that browser's keychain key. Nothing is changed there; everything lands in your own keychain, under Search.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .animation(Motion.settle, value: adding)
        .animation(Motion.settle, value: open)
        .onAppear { hunting = true }
    }

    /// A site, and under it its accounts once opened.
    private struct Site: View {
        let host: String
        let logins: [Kept]
        let open: Bool
        let toggle: () -> Void
        let copy: (Kept) -> Void
        let forget: (Kept) -> Void

        @State private var hovering = false

        var body: some View {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Mark(icon: Favicons.shared.cached(host), letter: host.first.map { String($0).uppercased() } ?? "•", size: 16)
                    Text(host)
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                    if logins.count > 1 {
                        Text("\(logins.count) accounts")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Palette.muted)
                    } else if let only = logins.first, !only.user.isEmpty, !open {
                        Text(only.user)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Palette.muted)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Palette.muted)
                        .rotationEffect(.degrees(open ? 90 : 0))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(open ? Palette.wash.opacity(0.6) : (hovering ? Palette.hover : .clear))
                .contentShape(Rectangle())
                .onTapGesture(perform: toggle)
                .onHover { hovering = $0 }
                .animation(Motion.quick, value: hovering)

                if open {
                    VStack(spacing: 0) {
                        ForEach(logins) { login in
                            Account(login: login, copy: { copy(login) }, forget: { forget(login) })
                        }
                    }
                    .padding(.leading, 30)
                    .padding(.trailing, 6)
                    .padding(.vertical, 4)
                    .transition(.opacity)
                }
            }
        }
    }

    /// One account: the name, the password as dots, and the three things to
    /// do with it. Show asks the Mac who you are first.
    private struct Account: View {
        let login: Kept
        let copy: () -> Void
        let forget: () -> Void

        @State private var hovering = false
        @State private var shown = false
        /// The secret, from the moment it is shown to the moment it is hidden
        /// again. Read on that click rather than with the list: see `Kept`.
        @State private var secret: String?
        @State private var hide: DispatchWorkItem?

        var body: some View {
            HStack(spacing: 10) {
                Text(login.user.isEmpty ? "No username" : login.user)
                    .font(.system(size: 12))
                    .foregroundStyle(login.user.isEmpty ? Palette.faint : Palette.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(minWidth: 120, alignment: .leading)

                // Ten dots whatever it is: the row does not know the length
                // until the secret is read, and a count that changed with it
                // told anyone looking over a shoulder how long it was.
                Text(shown ? (secret ?? "") : String(repeating: "•", count: 10))
                    .font(.system(size: shown ? 12.5 : 10, design: .monospaced))
                    .foregroundStyle(shown ? Palette.ink : Palette.muted)
                    .lineLimit(1)
                    .textSelection(.enabled)

                Spacer(minLength: 8)

                if hovering || shown {
                    Quick(shown ? "Hide" : "Show") { shown ? conceal() : reveal() }
                    Quick("Copy", act: copy)
                    Quick("Remove", tint: .red.opacity(0.75), act: forget)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(hovering ? Palette.hover : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .animation(Motion.quick, value: hovering)
            .animation(Motion.quick, value: shown)
            .onDisappear { conceal() }
        }

        private func reveal() {
            Vault.prove("show the password for \(login.host)") { ok in
                // Read after the Mac has said who this is, not before: the
                // secret is asked for here and let go with the row.
                guard ok, let password = Vault.secret(of: login) else { return }
                secret = password
                shown = true
                // Long enough to read or type across, and not a minute more.
                let work = DispatchWorkItem { conceal() }
                hide?.cancel()
                hide = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: work)
            }
        }

        /// Hidden again, and the secret with it: this is the only place it is
        /// held, and only while it is on screen.
        private func conceal() {
            hide?.cancel()
            shown = false
            secret = nil
        }
    }

    /// Typing one in by hand. The site, the name, the password, and Save.
    private struct AddForm: View {
        @ObservedObject var browser: Browser
        let done: () -> Void

        @State private var site = ""
        @State private var user = ""
        @State private var password = ""
        @FocusState private var focus: Int?

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    field("Site", text: $site, tag: 0)
                    field("Username", text: $user, tag: 1)
                }
                HStack(spacing: 8) {
                    ZStack(alignment: .leading) {
                        if password.isEmpty {
                            Text("Password").foregroundStyle(Palette.ink.opacity(0.3))
                                .padding(.leading, 10)
                        }
                        SecureField("", text: $password)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12.5, design: .monospaced))
                            .foregroundStyle(Palette.ink)
                            .focused($focus, equals: 2)
                            .onSubmit(keep)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                    }
                    .background(Palette.wash, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    Pill("Save", filled: true, action: keep)
                        .disabled(Vault.host(of: site).isEmpty || password.isEmpty)
                }
            }
            .padding(14)
            .onAppear { focus = 0 }
        }

        private func field(_ name: String, text: Binding<String>, tag: Int) -> some View {
            ZStack(alignment: .leading) {
                if text.wrappedValue.isEmpty {
                    Text(name).foregroundStyle(Palette.ink.opacity(0.3)).padding(.leading, 10)
                }
                TextField("", text: text)
                    .textFieldStyle(.plain)
                    .foregroundStyle(Palette.ink)
                    .focused($focus, equals: tag)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
            }
            .font(.system(size: 12.5))
            .background(Palette.wash, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }

        private func keep() {
            let host = Vault.host(of: site)
            guard !host.isEmpty, !password.isEmpty else { return }
            browser.keep(host: host, user: user.trimmingCharacters(in: .whitespaces), password: password)
            done()
        }
    }
}
