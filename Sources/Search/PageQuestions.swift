import SwiftUI

/// The same site permission question in a browser or a small popup window.
struct CaptureQuestion: View {
    @ObservedObject var browser: Browser
    let ask: Browser.CaptureAsk

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { question; actions }.fixedSize()
            VStack(alignment: .leading, spacing: 12) {
                question
                ViewThatFits(in: .horizontal) {
                    actions.fixedSize()
                    VStack(alignment: .leading, spacing: 10) { buttons }
                }
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .padding(.vertical, 9)
        .background(Palette.ground, in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Palette.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.12), radius: 20, y: 6)
    }

    private var question: some View {
        HStack(spacing: 12) {
            Image(systemName: ask.wants == "location" ? "location" : ask.wants == "microphone" ? "mic" : ask.wants == "notifications" ? "bell" : "video")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.muted)
            Text(ask.wants == "location" ? "\(ask.host) wants to know your location"
                 : ask.wants == "notifications" ? "\(ask.host) wants to send you notifications"
                 : "\(ask.host) wants to use your \(ask.wants)")
                .font(.system(size: 12.5))
                .foregroundStyle(Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var actions: some View {
        HStack(spacing: 12) { buttons }
    }

    @ViewBuilder
    private var buttons: some View {
        Button { ask.once ? browser.allowCaptureOnce() : browser.allowCapture() } label: {
            Text(ask.once ? "Allow once" : "Allow")
                .font(.system(size: 12))
                .foregroundStyle(Palette.ground)
                .padding(.horizontal, 11)
                .padding(.vertical, 5)
                .background(Palette.ink, in: Capsule())
        }
        .buttonStyle(.plain)
        if ask.once, ask.keeps {
            Button { browser.allowCapture() } label: {
                Text("Always allow")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.ink)
            }
            .buttonStyle(.plain)
        }
        Button { browser.denyCapture() } label: {
            Text("Don't allow")
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
        }
        .buttonStyle(.plain)
    }
}

/// A password offer remains readable in the popup that submitted the form.
struct PasswordOffer: View {
    @ObservedObject var browser: Browser
    let offer: Browser.Offer

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { question; actions }.fixedSize()
            VStack(alignment: .leading, spacing: 12) {
                question
                ViewThatFits(in: .horizontal) {
                    actions.fixedSize()
                    VStack(alignment: .leading, spacing: 10) { buttons }
                }
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .padding(.vertical, 9)
        .background(Palette.ground, in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Palette.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.12), radius: 20, y: 6)
    }

    private var question: some View {
        let login = offer.login
        return Text(offer.changed
             ? "Update the password for \(login.user) on \(login.host)?"
             : (login.user.isEmpty
                ? "Save this password for \(login.host)?"
                : "Save the password for \(login.user) on \(login.host)?"))
            .font(.system(size: 12.5))
            .foregroundStyle(Palette.ink)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var actions: some View { HStack(spacing: 12) { buttons } }

    @ViewBuilder
    private var buttons: some View {
        Button(offer.changed ? "Update" : "Save") { browser.keepOffer() }
            .buttonStyle(.plain)
            .font(.system(size: 12))
            .foregroundStyle(Palette.ground)
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(Palette.ink, in: Capsule())
        Button("Not now") { browser.dropOffer() }
            .buttonStyle(.plain)
            .font(.system(size: 12))
            .foregroundStyle(Palette.muted)
        if !offer.changed {
            Button("Never here") { browser.neverOffer() }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
        }
    }
}
