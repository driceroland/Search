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
        Plate(L("Passwords"), width: 620, close: { browser.managing = false }) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Hunt(text: $browser.hunting, prompt: L("Search sites and accounts"), focus: $hunting)
                    Pill(adding ? L("Cancel") : L("Add"), filled: !adding) { adding.toggle() }
                }

                if adding {
                    Card { AddForm(browser: browser) { adding = false } }
                        .transition(.opacity)
                }

                if browser.shownSites.isEmpty {
                    Card {
                        Nothing(browser.saved.isEmpty
                                ? L("Nothing kept yet. Sign in somewhere and say yes, or bring yours in below.")
                                : L("Nothing matches."))
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
                    Text(L("Bring in from"))
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
                    Pill(L("CSV file…")) { browser.importPasswords() }
                        .disabled(importing != nil)
                    Spacer(minLength: 0)
                    if let importing {
                        Ring(size: 10)
                        Text(L("Reading %@…", "\(importing)"))
                            .font(.system(size: 11.5))
                            .foregroundStyle(Palette.muted)
                    } else {
                        Text(browser.saved.count == 1 ? L("1 password") : L("%@ passwords", "\(browser.saved.count)"))
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.muted)
                    }
                }
                Text(L("macOS asks once for that browser's keychain key. Nothing is changed there; everything lands in your own keychain, under Search."))
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
        let logins: [Login]
        let open: Bool
        let toggle: () -> Void
        let copy: (Login) -> Void
        let forget: (Login) -> Void

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
                        Text(L("%@ accounts", "\(logins.count)"))
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
        let login: Login
        let copy: () -> Void
        let forget: () -> Void

        @State private var hovering = false
        @State private var shown = false
        @State private var hide: DispatchWorkItem?

        var body: some View {
            HStack(spacing: 10) {
                Text(login.user.isEmpty ? L("No username") : login.user)
                    .font(.system(size: 12))
                    .foregroundStyle(login.user.isEmpty ? Palette.faint : Palette.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(minWidth: 120, alignment: .leading)

                Text(shown ? login.password : String(repeating: "•", count: min(12, max(6, login.password.count))))
                    .font(.system(size: shown ? 12.5 : 10, design: .monospaced))
                    .foregroundStyle(shown ? Palette.ink : Palette.muted)
                    .lineLimit(1)
                    .textSelection(.enabled)

                Spacer(minLength: 8)

                if hovering || shown {
                    Quick(shown ? L("Hide") : L("Show")) { shown ? conceal() : reveal() }
                    Quick(L("Copy"), act: copy)
                    Quick(L("Remove"), tint: .red.opacity(0.75), act: forget)
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
            Vault.prove(L("show the password for %@", "\(login.host)")) { ok in
                guard ok else { return }
                shown = true
                // Long enough to read or type across, and not a minute more.
                let work = DispatchWorkItem { shown = false }
                hide?.cancel()
                hide = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: work)
            }
        }

        private func conceal() {
            hide?.cancel()
            shown = false
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
                    field(L("Site"), text: $site, tag: 0)
                    field(L("Username"), text: $user, tag: 1)
                }
                HStack(spacing: 8) {
                    ZStack(alignment: .leading) {
                        if password.isEmpty {
                            Text(L("Password")).foregroundStyle(Palette.ink.opacity(0.3))
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
                    Pill(L("Save"), filled: true, action: keep)
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
