// A new download's file, thrown from where it was clicked into the downloads
// button (#1552, after the pulse of #830). Settings › Appearance › Animate
// downloads; off unless turned on, and skipped with Reduce Motion, where the
// pulse alone stays and the Saved line says when the file is in.
//
// The numbers were settled in a sketch at the window's real size: a file's
// own Finder icon, thrown, 600 ms, rising 90 pt above the higher end, fading
// in over the first fifth so it lifts out of the click rather than popping up
// on it, swelling to half again its size at the top and landing at half. Then
// the button's own pulse, and once the file is in, a check for a moment.
//
// With the column folded away there is no button to land on: a small tab
// comes in at the window's edge, beside where the column would be, takes the
// file and its ring, and once the download is in goes back out the way it
// came.

import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

enum DownloadFlight {
    static let duration: Double = 0.6
    /// In Low Power Mode, as the pulse is quicker there (FetchDoor.pulse).
    static let lightDuration: Double = 0.4
    /// How far above the higher end, the click or the button, it rises.
    static let lift: CGFloat = 90
    /// Never closer than this to the window's top: in the strip across the
    /// top the button is only 26 pt down, and a full rise left the window.
    static let roof: CGFloat = 6
    /// The parts of the flight it takes to appear, and to go into the button.
    static let fadeIn: CGFloat = 0.2
    static let fadeOut: CGFloat = 0.12
    /// Its size at the top of the arc, and on landing, against its own.
    static let swell: CGFloat = 1.55
    static let landing: CGFloat = 0.5
    static let iconSize: CGFloat = 32
    /// A press older than this didn't start the download (a redirect or a
    /// page's script did, later): nothing is thrown, and the pulse plays.
    static let pressAge: CFTimeInterval = 2
    /// How long the check stays once the file is in, its fade included, and
    /// how long it takes to fade.
    static let check: Double = 0.16 + 0.9
    static let checkFade: Double = 0.16
    /// The tab at the window's edge: its size, the same distance from the
    /// side and the bottom, and how far it travels out when it goes.
    static let edgeSize: CGFloat = 24
    static let edgeInset: CGFloat = 12
    static let edgeTravel: CGFloat = 36

    static func duration(light: Bool) -> Double { light ? lightDuration : duration }

    /// Where the file is at `t` (0…1): across at a steady pace, up and down
    /// on a parabola through both ends that peaks `lift` above the higher.
    static func point(from a: CGPoint, to b: CGPoint, at t: CGFloat, lift: CGFloat = lift) -> CGPoint {
        let peak = max(roof, min(a.y, b.y) - lift)
        let rise = max(0, a.y - peak), fall = max(0, b.y - peak)
        // y(t) = p t² + q t + a.y, through b.y at 1, its top at `peak`.
        let q = -2 * (rise + (rise * fall).squareRoot())
        let p = (b.y - a.y) - q
        return CGPoint(x: a.x + (b.x - a.x) * t, y: p * t * t + q * t + a.y)
    }

    /// Its size at `t`: from its own toward `landing`, swollen at the top.
    static func scale(at t: CGFloat) -> CGFloat {
        let base = 1 + (landing - 1) * t
        return base * (1 + (swell - 1) * sin(.pi * min(1, t * 1.15)))
    }

    /// Fading in as it lifts off, out as it goes into the button.
    static func opacity(at t: CGFloat) -> Double {
        let coming = 1 - pow(1 - min(1, t / fadeIn), 2)
        let going = t > 1 - fadeOut ? (1 - t) / fadeOut : 1
        return Double(max(0, min(coming, going)))
    }
}

/// A file on its way to the downloads button.
struct DownloadTrip: Equatable {
    let id = UUID()
    /// Where the press was, in the window's top-left points.
    let from: CGPoint
    let icon: NSImage
    let began = Date()
    let duration: Double
    /// To the tab at the window's edge, the column folded away.
    let edge: Bool

    static func == (a: DownloadTrip, b: DownloadTrip) -> Bool { a.id == b.id }
}

/// The downloads button a window shows, for a flight to aim at. Held, not
/// drawn from: it moves as it comes in, and the flight follows it there.
final class DoorSpot {
    weak var view: NSView?

    /// Its frame in its window's top-left points; nil while it isn't shown.
    var frame: CGRect? {
        guard let view, let window = view.window, let content = window.contentView,
              !view.isHiddenOrHasHiddenAncestor else { return nil }
        let rect = view.convert(view.bounds, to: nil)
        let frame = CGRect(x: rect.minX, y: content.bounds.height - rect.maxY, width: rect.width, height: rect.height)
        // Slid out of the window with the column: not shown.
        return frame.intersects(content.bounds) ? frame : nil
    }
}

extension Browser {
    /// A download just begun in this window: thrown from the press that
    /// started it, if one did a moment ago.
    func launchFlight(for download: WKDownload) {
        guard prefs.animatesDownloads, !Motion.reduced, !isPopup, let press = lastPress,
              CACurrentMediaTime() - press.time < DownloadFlight.pressAge,
              window?.isVisible == true else { return }
        // One press, one flight: a second download a page starts on its own
        // isn't thrown from the same spot.
        lastPress = nil
        let ext = download.originalRequest?.url?.pathExtension ?? ""
        let type = ext.isEmpty ? UTType.data : (UTType(filenameExtension: ext) ?? .data)
        let edge = folded && !peeking
        let trip = DownloadTrip(from: press.at, icon: NSWorkspace.shared.icon(for: type),
                                duration: DownloadFlight.duration(light: Motion.light), edge: edge)
        if edge { withAnimation(.easeOut(duration: 0.2)) { downloadsEdge = true } }
        flight = trip
        DispatchQueue.main.asyncAfter(deadline: .now() + trip.duration) { [weak self] in
            guard let self, self.flight == trip else { return }
            self.flight = nil
            self.doorBeat += 1
        }
    }
}

/// Over the whole window, taking no clicks: the file on its way, and the
/// tab at the window's edge while the column is folded away.
struct DownloadFlightLayer: View {
    @ObservedObject var browser: Browser
    @ObservedObject var fetches: Fetches
    /// The column on the right: the edge tab comes in there.
    let onRight: Bool

    var body: some View {
        GeometryReader { box in
            let origin = box.frame(in: .global).origin
            ZStack(alignment: .topLeading) {
                if browser.downloadsEdge {
                    DownloadsEdge(browser: browser, fetches: fetches)
                        .position(edgeCenter(in: box.size))
                        .transition(.offset(x: onRight ? DownloadFlight.edgeTravel : -DownloadFlight.edgeTravel)
                            .combined(with: .opacity))
                }
                if let trip = browser.flight {
                    TimelineView(.animation) { context in
                        let t = CGFloat(min(1, max(0, context.date.timeIntervalSince(trip.began) / trip.duration)))
                        let from = CGPoint(x: trip.from.x - origin.x, y: trip.from.y - origin.y)
                        let to = target(for: trip, origin: origin, size: box.size)
                        Image(nsImage: trip.icon)
                            .resizable()
                            .frame(width: DownloadFlight.iconSize, height: DownloadFlight.iconSize)
                            .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
                            .scaleEffect(DownloadFlight.scale(at: t))
                            .opacity(DownloadFlight.opacity(at: t))
                            .position(DownloadFlight.point(from: from, to: to, at: t))
                    }
                }
            }
            .frame(width: box.size.width, height: box.size.height, alignment: .topLeading)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        // The file in: the edge tab shows its check, then goes out the way
        // it came. A failure, or the column back out, takes it at once.
        .onChange(of: fetches.done) { _, done in
            guard done, browser.downloadsEdge else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + DownloadFlight.check) {
                withAnimation(.timingCurve(0.4, 0, 1, 1, duration: 0.26)) { browser.downloadsEdge = false }
            }
        }
        .onChange(of: fetches.showing) { _, showing in
            if !showing, browser.downloadsEdge { browser.downloadsEdge = false }
        }
        .onChange(of: browser.folded) { _, folded in
            if !folded, browser.downloadsEdge { browser.downloadsEdge = false }
        }
    }

    private func edgeCenter(in size: CGSize) -> CGPoint {
        let inset = DownloadFlight.edgeInset + DownloadFlight.edgeSize / 2
        return CGPoint(x: onRight ? size.width - inset : inset, y: size.height - inset)
    }

    /// The button's middle, wherever it has got to; the edge tab's with the
    /// column folded, or with no button shown.
    private func target(for trip: DownloadTrip, origin: CGPoint, size: CGSize) -> CGPoint {
        if !trip.edge, let frame = browser.doorSpot.frame {
            return CGPoint(x: frame.midX - origin.x, y: frame.midY - origin.y)
        }
        return edgeCenter(in: size)
    }
}

/// The downloads button's stand-in at the window's edge, the column folded
/// away: what the button would show, on the ground the Saved line has.
private struct DownloadsEdge: View {
    @ObservedObject var browser: Browser
    @ObservedObject var fetches: Fetches

    var body: some View {
        FetchGlyph(fetches: fetches, check: true)
            .keyframeAnimator(initialValue: CGFloat(1), trigger: browser.doorBeat) { icon, scale in
                icon.scaleEffect(scale)
            } keyframes: { _ in
                let pulse = FetchDoor.pulse(reduced: Motion.reduced, light: Motion.light)
                CubicKeyframe(pulse.peak, duration: pulse.up)
                CubicKeyframe(1, duration: pulse.down)
            }
            .frame(width: DownloadFlight.edgeSize, height: DownloadFlight.edgeSize)
            .background(Palette.ground, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
            .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
            .animation(Motion.quick, value: fetches.done)
            .animation(Motion.quick, value: fetches.showing)
    }
}
