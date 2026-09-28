import AppKit
import SwiftUI
import WebKit

// Responsive Design Mode: the tab in front laid out as a phone or a tablet
// would lay it out — at that screen's width and height, with its pixel
// density and the user agent its own browser sends — in a frame in the
// middle of the stage, with a bar above it to pick another device, turn it
// on its side, or zoom it to fit. Chrome's device toolbar and Safari's
// Responsive Design Mode, from the View menu.
//
// The page keeps its own size in CSS pixels however small the frame on
// screen: WebKit scales the view and lays it out at the size divided by the
// same scale. Both that and the pixel density are WebKit's names outside the
// public framework — the ones Safari's own mode uses — asked for before use
// (see Inspector.swift); a WebKit without them shows the page at full size,
// cut to the frame.

struct Device: Hashable, Identifiable {
    enum Kind { case phone, tablet, responsive }

    let name: String
    let kind: Kind
    /// In CSS pixels, upright.
    let width: Int
    let height: Int
    /// window.devicePixelRatio; 0 leaves the Mac's own.
    let scale: CGFloat
    /// Nil keeps the one every page gets.
    let agent: String?

    var id: String { name }

    private static let iPhone = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1"
    private static let iPad = "Mozilla/5.0 (iPad; CPU OS 18_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1"
    /// Chrome's reduced user agent: the same Android and model for every
    /// phone, as Chrome itself now sends.
    private static let android = "Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Mobile Safari/537.36"

    /// The window's own user agent and density, at a size of your choosing.
    static let responsive = Device(name: "Responsive", kind: .responsive, width: 400, height: 800, scale: 0, agent: nil)

    /// Chrome's list, with this year's iPhones.
    static let iPhones = [
        Device(name: "iPhone SE", kind: .phone, width: 375, height: 667, scale: 2, agent: iPhone),
        Device(name: "iPhone X", kind: .phone, width: 375, height: 812, scale: 3, agent: iPhone),
        Device(name: "iPhone 14", kind: .phone, width: 390, height: 844, scale: 3, agent: iPhone),
        Device(name: "iPhone 16 Pro", kind: .phone, width: 402, height: 874, scale: 3, agent: iPhone),
        Device(name: "iPhone 16 Pro Max", kind: .phone, width: 440, height: 956, scale: 3, agent: iPhone),
    ]
    static let androids = [
        Device(name: "Pixel 7", kind: .phone, width: 412, height: 915, scale: 2.625, agent: android),
        Device(name: "Samsung Galaxy S20 Ultra", kind: .phone, width: 412, height: 915, scale: 3.5, agent: android),
        Device(name: "Samsung Galaxy S8+", kind: .phone, width: 360, height: 740, scale: 4, agent: android),
    ]
    static let iPads = [
        Device(name: "iPad Mini", kind: .tablet, width: 768, height: 1024, scale: 2, agent: iPad),
        Device(name: "iPad Air", kind: .tablet, width: 820, height: 1180, scale: 2, agent: iPad),
        Device(name: "iPad Pro", kind: .tablet, width: 1024, height: 1366, scale: 2, agent: iPad),
    ]
}

/// A tab's Responsive Design Mode: which device, which way up, at what zoom.
struct Emulation: Equatable {
    var device: Device
    /// In CSS pixels, as the page sees them — turned when the device is.
    var width: Int
    var height: Int
    /// Nil zooms to fit the stage, never past 100%.
    var zoom: CGFloat?

    init(_ device: Device, zoom: CGFloat? = nil) {
        self.device = device
        width = device.width
        height = device.height
        self.zoom = zoom
    }

    var landscape: Bool { width > height }
    var size: CGSize { CGSize(width: width, height: height) }

    /// The one the next tab opens with: the last one picked.
    static var last = Emulation(Device.iPhones[1])
}

extension Tab {
    /// Turns the mode on with the last device, or off.
    func toggleEmulation() {
        emulation = emulation == nil ? Emulation.last : nil
    }
}

extension PageView {
    /// Hands the page its device, or nil for the Mac again. True when the
    /// user agent changed, which a page only reads as it loads.
    @discardableResult
    func emulate(_ emulation: Emulation?) -> Bool {
        emulated = emulation
        let agent = emulation?.device.agent
        let changed = (customUserAgent ?? "").isEmpty ? agent != nil : customUserAgent != agent
        if changed { customUserAgent = agent }
        if emulation == nil {
            layout(0)
            viewScale = 1
            density(0)
        }
        return changed
    }

    /// The page drawn at `scale` of its CSS pixels, and its pixel density
    /// the device's all the same: WebKit multiplies the density it is given
    /// by the view's scale, so a phone zoomed to fit at 82% would read as
    /// 2.46 rather than 3.
    func fit(_ scale: CGFloat) {
        // Laid out at the frame divided by the scale, both ways. The view's
        // own size, the usual way, divides only the width: a phone zoomed to
        // fit had a 100vh of 82% of its height, with anything fixed to the
        // bottom of the screen that far up it.
        layout(emulated == nil ? 0 : 2)
        viewScale = scale
        guard let device = emulated?.device else { return density(0) }
        if device.scale > 0 {
            density(device.scale / scale)
        } else {
            // Responsive keeps the screen's own, at whatever zoom.
            density(scale == 1 ? 0 : (window?.backingScaleFactor ?? 2) / scale)
        }
    }

    /// WebKit's _WKLayoutMode: 0 lays the page out at the view's size, 2 at
    /// that size divided by the view's scale.
    private func layout(_ mode: UInt) {
        let get = NSSelectorFromString("_layoutMode"), put = NSSelectorFromString("_setLayoutMode:")
        guard responds(to: get), responds(to: put) else { return }
        typealias Getter = @convention(c) (AnyObject, Selector) -> UInt
        typealias Setter = @convention(c) (AnyObject, Selector, UInt) -> Void
        guard unsafeBitCast(method(for: get), to: Getter.self)(self, get) != mode else { return }
        unsafeBitCast(method(for: put), to: Setter.self)(self, put, mode)
    }

    /// WebKit's override of window.devicePixelRatio; 0 for none. Set only
    /// when it changes, as each one draws the page again.
    private func density(_ value: CGFloat) {
        guard abs(value - density) > 0.0001 else { return }
        density = value
        set("_setOverrideDeviceScaleFactor:", value)
    }

    /// How much smaller than its CSS pixels the page is drawn: its layout is
    /// the frame divided by this.
    var viewScale: CGFloat {
        get {
            let selector = NSSelectorFromString("_viewScale")
            guard responds(to: selector) else { return 1 }
            typealias Getter = @convention(c) (AnyObject, Selector) -> CGFloat
            return unsafeBitCast(method(for: selector), to: Getter.self)(self, selector)
        }
        set {
            // WebKit throws on anything but a positive number, and lays the
            // page out again on every call, the same scale included.
            guard newValue > 0, newValue.isFinite, abs(newValue - viewScale) > 0.0001 else { return }
            set("_setViewScale:", newValue)
        }
    }

    private func set(_ name: String, _ value: CGFloat) {
        let selector = NSSelectorFromString(name)
        guard responds(to: selector) else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, CGFloat) -> Void
        unsafeBitCast(method(for: selector), to: Setter.self)(self, selector, value)
    }
}

/// Where a page in Responsive Design Mode goes on its stage (see StageView).
enum DeviceFrame {
    /// Room kept above the device for its bar.
    static let bar: CGFloat = 44
    /// And around it, so the device reads as one.
    static let margin: CGFloat = 16

    /// The frame, in the stage's coordinates (AppKit's, from the bottom),
    /// and the scale the page is drawn at inside it. `room` is what the stage
    /// has left — all of it, or what the Web Inspector docked beside the
    /// page leaves.
    static func place(_ emulation: Emulation, in room: CGRect) -> (frame: CGRect, scale: CGFloat) {
        let size = emulation.size
        let space = CGSize(width: max(1, room.width - 2 * margin), height: max(1, room.height - bar - margin))
        let fit = min(1, space.width / size.width, space.height / size.height)
        let wanted = emulation.zoom ?? fit
        // Whole points across, so the page isn't drawn between pixels, and
        // the scale taken from that width, so its layout is still exactly
        // the device's.
        let width = max(1, (size.width * wanted).rounded())
        let scale = width / size.width
        let height = (size.height * scale).rounded()
        let x = room.minX + max(margin, (room.width - width) / 2)
        let y = room.maxY - bar - height
        return (CGRect(x: x.rounded(), y: y, width: width, height: height), scale)
    }
}

/// The bar over a page in Responsive Design Mode.
struct DeviceBar: View {
    @ObservedObject var tab: Tab

    @State private var width = ""
    @State private var height = ""

    var body: some View {
        if let emulation = tab.emulation {
            HStack(spacing: 4) {
                Menu {
                    pick(Device.responsive)
                    Divider()
                    Section("iPhone") { ForEach(Device.iPhones) { pick($0) } }
                    Section("Android") { ForEach(Device.androids) { pick($0) } }
                    Section("iPad") { ForEach(Device.iPads) { pick($0) } }
                } label: {
                    Text(emulation.device.name)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .padding(.trailing, 6)

                if emulation.device.kind == .responsive {
                    field($width, \.width)
                    Text("×").foregroundStyle(Palette.muted)
                    field($height, \.height)
                } else {
                    Text("\(emulation.width) × \(emulation.height)")
                        .monospacedDigit()
                        .foregroundStyle(Palette.muted)
                }

                Menu {
                    Button("Fit") { update { $0.zoom = nil } }
                    Divider()
                    ForEach([50, 75, 100, 125, 150], id: \.self) { percent in
                        Button("\(percent)%") { update { $0.zoom = CGFloat(percent) / 100 } }
                    }
                } label: {
                    Text(emulation.zoom.map { "\(Int(($0 * 100).rounded()))%" } ?? "Fit")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .padding(.leading, 10)

                if emulation.device.scale > 0 {
                    Text("DPR \(Self.ratio(emulation.device.scale))")
                        .foregroundStyle(Palette.muted)
                        .padding(.leading, 6)
                }

                button("rotate.right", help: "Rotate") {
                    update { swap(&$0.width, &$0.height) }
                }
                .padding(.leading, 6)
                button("arrow.clockwise", help: "Reload") { tab.reload() }
                button("xmark", help: "Leave Responsive Design Mode") { tab.emulation = nil }
            }
            .font(.system(size: 12))
            .foregroundStyle(Palette.ink)
            .padding(.leading, 14)
            .padding(.trailing, 6)
            .frame(height: 30)
            .background(Palette.ground, in: Capsule())
            .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 1))
            .shadow(color: .black.opacity(0.08), radius: 10, y: 3)
            .padding(.top, 7)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .onAppear { read(emulation) }
            .onChange(of: emulation) { _, now in read(now) }
        }
    }

    /// 3, 2.625: as many places as it has, and no more.
    private static func ratio(_ scale: CGFloat) -> String {
        var text = String(format: "%.3f", Double(scale))
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    private func read(_ emulation: Emulation) {
        width = String(emulation.width)
        height = String(emulation.height)
    }

    private func pick(_ device: Device) -> some View {
        Button(device.name) {
            guard var emulation = tab.emulation else { return }
            // The way up is kept from one device to the next, as in Chrome.
            let landscape = emulation.landscape
            emulation.device = device
            emulation.width = landscape ? device.height : device.width
            emulation.height = landscape ? device.width : device.height
            tab.emulation = emulation
        }
    }

    private func update(_ change: (inout Emulation) -> Void) {
        guard var emulation = tab.emulation else { return }
        change(&emulation)
        tab.emulation = emulation
    }

    /// A side of a Responsive device, typed in: anything that isn't a
    /// sensible number of pixels puts back the one there was.
    private func field(_ text: Binding<String>, _ side: WritableKeyPath<Emulation, Int>) -> some View {
        TextField("", text: text)
            .textFieldStyle(.plain)
            .multilineTextAlignment(.center)
            .monospacedDigit()
            .frame(width: 40)
            .onSubmit {
                guard let emulation = tab.emulation else { return }
                guard let number = Int(text.wrappedValue.trimmingCharacters(in: .whitespaces)), (50...4000).contains(number) else {
                    read(emulation)
                    return
                }
                update { $0[keyPath: side] = number }
            }
    }

    private func button(_ icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.muted)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
