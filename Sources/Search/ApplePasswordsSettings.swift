import SwiftUI

/// Settings › Passwords: the switch for the Mac's Passwords app, and, once
/// on, the pairing — Connect…, the code your Mac shows typed in here, and
/// Disconnect. The code is typed into Search, never into a page.
struct ApplePasswordsCard: View {
    @ObservedObject var prefs: Preferences
    @ObservedObject private var apple = ApplePasswords.shared
    @State private var code = ""
    @FocusState private var typing: Bool

    var body: some View {
        Card {
            Line("Passwords from Apple's Passwords app",
                 "Accounts saved in the Passwords app, under the sign-in box. Unofficial: Search talks to the helper Apple made for its Chrome extension, as that extension. Never in private tabs.") {
                Switch(on: $prefs.applePasswords)
            }
            if prefs.applePasswords {
                Rule()
                pairing
            }
        }
        .onChange(of: apple.state) { _, state in
            code = ""
            if state == .code { typing = true }
        }
    }

    @ViewBuilder private var pairing: some View {
        switch apple.state {
        case .idle:
            Line(apple.trouble ?? "Not connected", "Your Mac shows a code, and you type it here. Once per launch of Search, and only when you first want an account: under a sign-in box, Connect Apple Passwords… asks for it there.") {
                Pill("Connect…") { Task { await apple.connect() } }
            }
        case .starting:
            Line("Connecting…", "Waiting for your Mac to show a code") { EmptyView() }
        case .code, .checking:
            Line("Enter the code your Mac shows", apple.state == .checking ? "Checking…" : "Six digits, from the Passwords window") {
                HStack(spacing: 8) {
                    TextField("000000", text: $code)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, design: .monospaced))
                        .frame(width: 70)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Palette.wash, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .focused($typing)
                        .onChange(of: code) { _, typed in
                            let digits = String(typed.filter(\.isNumber).prefix(6))
                            if digits != typed { code = digits }
                            // Six digits are the whole code: sent without OK.
                            if digits.count == 6 { send() }
                        }
                        .onSubmit(send)
                        .disabled(apple.state == .checking)
                    Pill("OK", filled: true, action: send)
                    Pill("Cancel") { apple.disconnect() }
                }
            }
        case .paired:
            Line("Connected", "Until Search quits. Accounts show under sign-in boxes, marked Apple Passwords; macOS may ask for Touch ID before one is filled.") {
                Pill("Disconnect") { apple.disconnect() }
            }
        }
    }

    private func send() {
        guard code.count == 6, apple.state == .code else { return }
        let typed = code
        code = ""
        Task { await apple.enter(typed) }
    }
}

/// Connect Apple Passwords, from under a sign-in box: a small card of
/// Search's own where the list was, that takes the code your Mac shows and
/// goes once paired, the caret back in the box. Six digits are sent as soon
/// as they are typed. Esc or Cancel stops the helper, its window with it.
struct ApplePairingCard: View {
    @ObservedObject var browser: Browser
    @ObservedObject var apple: ApplePasswords
    let pairing: Browser.ApplePairing
    @State private var code = ""
    @FocusState private var typing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "key.icloud")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Palette.ink)
                    .frame(width: 22, height: 22)
                    .background(Palette.wash, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Palette.ink)
                    Text(detail)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Palette.muted)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                if apple.state == .code || apple.state == .checking {
                    TextField("000000", text: $code)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, design: .monospaced))
                        .frame(width: 70)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Palette.wash, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .focused($typing)
                        .disabled(apple.state == .checking)
                        .onChange(of: code) { _, typed in
                            let digits = String(typed.filter(\.isNumber).prefix(6))
                            if digits != typed { code = digits }
                            if digits.count == 6 { send() }
                        }
                        .onSubmit(send)
                } else if apple.state == .idle {
                    Pill("Try again", filled: true) { Task { await apple.connect() } }
                }
                Spacer(minLength: 0)
                Pill("Cancel") { browser.endApplePairing(paired: false) }
            }
        }
        .padding(10)
        .frame(width: max(240, min(360, pairing.spot.width)), alignment: .leading)
        .background(Palette.ground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Palette.hairline, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.14), radius: 22, y: 8)
        .offset(x: pairing.spot.minX, y: pairing.spot.maxY + 6)
        .onExitCommand { browser.endApplePairing(paired: false) }
        .onAppear { if apple.state == .code { typing = true } }
        .onChange(of: apple.state) { _, state in
            code = ""
            if state == .code { typing = true }
        }
    }

    private var title: String {
        switch apple.state {
        case .idle: return apple.trouble ?? "Not connected"
        case .starting: return "Connecting to Apple Passwords…"
        case .code: return "Enter the code your Mac shows"
        case .checking: return "Checking…"
        case .paired: return "Connected"
        }
    }

    private var detail: String {
        switch apple.state {
        case .starting: return "Your Mac shows a six-digit code in a moment"
        case .code, .checking: return "Six digits, from the Passwords window. Once per launch of Search."
        default: return "Apple Passwords"
        }
    }

    private func send() {
        guard code.count == 6, apple.state == .code else { return }
        let typed = code
        code = ""
        Task { await apple.enter(typed) }
    }
}
