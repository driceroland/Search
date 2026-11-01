import SwiftUI
import AppKit
import Combine

/// A page's own fullscreen state changes without changing the Browser's tab
/// identity. Listen to both visible pages so the surrounding chrome follows.
struct TabImmersionWatch: View {
    let tab: Tab
    let changed: () -> Void

    var body: some View {
        // Once the flag has changed (Tab.immersion), never before: what the
        // window works out from it at once must read the new value.
        Color.clear.frame(width: 0, height: 0)
            .onReceive(tab.immersion) { _ in changed() }
    }
}

/// SwiftUI's window, around whichever browser it holds now (see SceneSlot):
/// a fresh one, laid out afresh, when the old one went with its window.
struct SceneRoot: View {
    @ObservedObject var slot: SceneSlot

    var body: some View {
        ContentView(browser: slot.browser)
            .id(ObjectIdentifier(slot.browser))
            .onAppear { Browsers.restoreOnce() }
    }
}

/// A file being brought in, in the background (#380): its name, how far it
/// has got, and Cancel — in the corner, in the quiet grey of everything
/// else that floats over the page.
struct ImportProgress: View {
    @ObservedObject var browser: Browser
    let job: Browser.FileImportJob

    private var fraction: CGFloat? {
        guard let total = job.total, total > 0 else { return nil }
        return min(1, CGFloat(job.completed) / CGFloat(total))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(job.filename)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(job.message)
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
                .lineLimit(1)
            bar
            footer
        }
        .padding(14)
        .frame(width: 250, alignment: .leading)
        .background(Palette.ground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.08), radius: 16, y: 5)
        .padding(20)
        .transition(.opacity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Importing \(job.filename), \(job.message)")
    }

    private var bar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.hairline)
                if let fraction {
                    Capsule().fill(Palette.ink.opacity(0.7)).frame(width: geo.size.width * fraction)
                }
            }
        }
        .frame(height: 3)
    }

    private var footer: some View {
        HStack {
            if let total = job.total, total > 0 {
                Text("\(job.completed.formatted()) of \(total.formatted())")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.muted)
            }
            Spacer(minLength: 0)
            Button { browser.cancelFileImport() } label: {
                Text(job.cancelling ? "Cancelling…" : "Cancel")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.ink)
                    .padding(.horizontal, 10)
                    .frame(height: 22)
                    .background(Palette.ink.opacity(0.07), in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(job.cancelling)
        }
    }
}
