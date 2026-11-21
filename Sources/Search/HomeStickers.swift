import SwiftUI

/// Ten sticker packs, drawn in code. A sticker is a few layers in a unit
/// square around the origin; the die-cut white edge and soft shadow are
/// made from the layers themselves. Scattered with a fixed seed, slightly
/// tilted, and kept out of the middle where the address field sits.
enum HomeStickers {
    /// One layer: a path, a colour (palette index; -1 ink, -2 white, -3 the
    /// pack's ground), and a line width (0 fills).
    fileprivate typealias Layer = (path: Path, colour: Int, width: CGFloat)

    // MARK: shape helpers

    private static func f(_ p: Path, _ c: Int) -> Layer { (p, c, 0) }
    private static func s(_ p: Path, _ c: Int, _ w: CGFloat = 0.1) -> Layer { (p, c, w) }

    private static func disc(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
    }
    private static func oval(_ x: CGFloat, _ y: CGFloat, _ rx: CGFloat, _ ry: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: x - rx, y: y - ry, width: rx * 2, height: ry * 2))
    }
    private static func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat = 0) -> Path {
        Path(roundedRect: CGRect(x: x - w / 2, y: y - h / 2, width: w, height: h), cornerRadius: r)
    }
    /// Points as x, y, x, y...; closed when filled.
    private static func poly(_ v: [CGFloat], closed: Bool = true) -> Path {
        var p = Path()
        var i = 0
        while i + 1 < v.count {
            let q = CGPoint(x: v[i], y: v[i + 1])
            i == 0 ? p.move(to: q) : p.addLine(to: q)
            i += 2
        }
        if closed { p.closeSubpath() }
        return p
    }
    private static func arc(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat, _ a: Double, _ b: Double, close: Bool = false) -> Path {
        var p = Path()
        p.addArc(center: CGPoint(x: x, y: y), radius: r, startAngle: .degrees(a), endAngle: .degrees(b), clockwise: false)
        if close { p.closeSubpath() }
        return p
    }
    private static func star(_ n: Int, _ outer: CGFloat, _ inner: CGFloat, _ cx: CGFloat = 0, _ cy: CGFloat = 0) -> Path {
        var p = Path()
        for k in 0..<(n * 2) {
            let a = -Double.pi / 2 + Double(k) * .pi / Double(n)
            let r = k % 2 == 0 ? outer : inner
            let q = CGPoint(x: cx + r * CGFloat(cos(a)), y: cy + r * CGFloat(sin(a)))
            k == 0 ? p.move(to: q) : p.addLine(to: q)
        }
        p.closeSubpath()
        return p
    }
    private static func sparkle(_ cx: CGFloat, _ cy: CGFloat, _ k: CGFloat) -> Path {
        var p = Path()
        let d = 0.13 * k
        p.move(to: CGPoint(x: cx, y: cy - k))
        p.addQuadCurve(to: CGPoint(x: cx + k, y: cy), control: CGPoint(x: cx + d, y: cy - d))
        p.addQuadCurve(to: CGPoint(x: cx, y: cy + k), control: CGPoint(x: cx + d, y: cy + d))
        p.addQuadCurve(to: CGPoint(x: cx - k, y: cy), control: CGPoint(x: cx - d, y: cy + d))
        p.addQuadCurve(to: CGPoint(x: cx, y: cy - k), control: CGPoint(x: cx - d, y: cy - d))
        p.closeSubpath()
        return p
    }
    private static func rays(_ n: Int, _ r0: CGFloat, _ r1: CGFloat) -> Path {
        var p = Path()
        for k in 0..<n {
            let a = Double(k) * 2 * .pi / Double(n)
            p.move(to: CGPoint(x: r0 * CGFloat(cos(a)), y: r0 * CGFloat(sin(a))))
            p.addLine(to: CGPoint(x: r1 * CGFloat(cos(a)), y: r1 * CGFloat(sin(a))))
        }
        return p
    }
    private static func turned(_ p: Path, _ a: CGFloat) -> Path { p.applying(CGAffineTransform(rotationAngle: a)) }

    // MARK: packs

    /// Ground colour and the colours its stickers are made of.
    private static func look(_ pack: StickerPack) -> (ground: RGB, palette: [RGB]) {
        switch pack {
        case .space:
            return ((0.88, 0.86, 0.97), [(0.42, 0.40, 0.85), (0.98, 0.80, 0.32), (0.35, 0.66, 0.88), (0.90, 0.50, 0.72), (0.98, 0.58, 0.40)])
        case .roadTrip:
            return ((0.98, 0.93, 0.82), [(0.30, 0.62, 0.62), (0.97, 0.78, 0.30), (0.90, 0.40, 0.35), (0.45, 0.70, 0.45), (0.30, 0.35, 0.55)])
        case .ocean:
            return ((0.84, 0.93, 0.96), [(0.30, 0.60, 0.85), (0.98, 0.55, 0.50), (0.98, 0.82, 0.45), (0.35, 0.75, 0.70), (0.25, 0.35, 0.60)])
        case .jungle:
            return ((0.88, 0.95, 0.84), [(0.35, 0.65, 0.40), (0.20, 0.45, 0.35), (0.98, 0.82, 0.35), (0.95, 0.45, 0.35), (0.30, 0.60, 0.85)])
        case .streetFood:
            return ((0.99, 0.91, 0.80), [(0.97, 0.65, 0.30), (0.90, 0.35, 0.30), (0.98, 0.84, 0.50), (0.50, 0.75, 0.45), (0.60, 0.40, 0.30)])
        case .retroTech:
            return ((0.92, 0.90, 0.84), [(0.35, 0.65, 0.70), (0.90, 0.40, 0.60), (0.98, 0.80, 0.35), (0.55, 0.45, 0.80), (0.25, 0.28, 0.45)])
        case .weather:
            return ((0.88, 0.94, 0.98), [(0.50, 0.74, 0.95), (0.99, 0.80, 0.30), (0.62, 0.70, 0.82), (0.96, 0.50, 0.45), (0.40, 0.38, 0.72)])
        case .music:
            return ((0.96, 0.90, 0.93), [(0.92, 0.42, 0.45), (0.60, 0.45, 0.85), (0.98, 0.80, 0.35), (0.35, 0.72, 0.70), (0.25, 0.22, 0.38)])
        case .wonders:
            return ((0.97, 0.92, 0.84), [(0.93, 0.75, 0.45), (0.85, 0.35, 0.30), (0.30, 0.65, 0.65), (0.62, 0.60, 0.76), (0.50, 0.34, 0.26), (0.80, 0.60, 0.32)])
        case .search:
            return ((0.90, 0.92, 0.98), [(0.35, 0.55, 0.95), (0.98, 0.60, 0.30), (0.40, 0.80, 0.65), (0.65, 0.50, 0.90), (0.95, 0.50, 0.60), (0.80, 0.80, 0.88)])
        }
    }

    private static func stickers(_ pack: StickerPack) -> [[Layer]] {
        switch pack {
        case .space: return space()
        case .roadTrip: return roadTrip()
        case .ocean: return ocean()
        case .jungle: return jungle()
        case .streetFood: return streetFood()
        case .retroTech: return retroTech()
        case .weather: return weather()
        case .music: return music()
        case .wonders: return wonders()
        case .search: return search()
        }
    }

    private static func ringHalf(_ front: Bool) -> Path {
        turned(arc(0, 0, 1, front ? 0 : 180, front ? 180 : 360).applying(CGAffineTransform(scaleX: 1.05, y: 0.3)), -0.4)
    }

    private static func space() -> [[Layer]] {
        [
            [s(ringHalf(false), 1, 0.13), f(disc(0, 0, 0.62), 0), s(arc(0, 0, 0.45, 200, 300), 3, 0.08), s(ringHalf(true), 1, 0.13)],
            [f(poly([-0.2, 0.55, 0, 1.1, 0.2, 0.55]), 1), f(poly([-0.35, 0.6, -0.35, -0.2, 0, -1, 0.35, -0.2, 0.35, 0.6]), -2),
             f(poly([-0.35, 0.15, -0.75, 0.75, -0.35, 0.6]), 4), f(poly([0.35, 0.15, 0.75, 0.75, 0.35, 0.6]), 4),
             f(poly([-0.35, -0.2, 0, -1, 0.35, -0.2]), 4), f(disc(0, 0, 0.2), 2), s(disc(0, 0, 0.2), 0, 0.06)],
            [f(disc(0, 0, 0.85), -2), s(disc(0, 0, 0.85), 0, 0.1), f(box(0, 0.05, 1.1, 0.7, 0.3), 0),
             f(oval(-0.3, -0.12, 0.2, 0.1), 2), f(disc(-0.95, 0.1, 0.12), 1), f(disc(0.95, 0.1, 0.12), 1)],
            [f(star(5, 1, 0.45), 1), f(disc(-0.15, -0.1, 0.07), -1), f(disc(0.15, -0.1, 0.07), -1)],
            [f(poly([0.05, -0.6, 0.6, -0.05, -0.9, 0.9]), 1), s(poly([-0.2, 0.2, 0.3, -0.3], closed: false), 3, 0.08),
             f(disc(0.35, -0.35, 0.38), 4)],
            [f(arc(0, -0.1, 0.45, 180, 360, close: true), 2), f(oval(0, 0.15, 0.95, 0.3), 0), f(disc(-0.5, 0.2, 0.07), 1),
             f(disc(0, 0.28, 0.07), 1), f(disc(0.5, 0.2, 0.07), 1)]
        ]
    }

    private static func roadTrip() -> [[Layer]] {
        [
            [f(box(0, 0.05, 1.8, 0.95, 0.28), 0), f(box(0, 0.32, 1.8, 0.4, 0.14), 1), f(box(-0.4, -0.15, 0.55, 0.38, 0.08), -2),
             f(box(0.35, -0.15, 0.45, 0.38, 0.08), -2), f(disc(-0.55, 0.56, 0.22), -1), f(disc(0.55, 0.56, 0.22), -1),
             f(disc(-0.55, 0.56, 0.08), -2), f(disc(0.55, 0.56, 0.08), -2)],
            [f(disc(0, -0.25, 0.6), 2), f(poly([-0.5, 0.05, 0, 0.95, 0.5, 0.05]), 2), f(disc(0, -0.25, 0.22), -2)],
            [f(box(0, 0.7, 0.12, 0.9), 4), f(poly([0, -0.95, 0.8, -0.2, 0, 0.55, -0.8, -0.2]), 1),
             s(poly([-0.3, -0.05, 0, -0.4, 0.3, -0.05], closed: false), -1, 0.13)],
            [f(disc(0, 0, 0.5), 1), s(rays(8, 0.7, 0.97), 1, 0.15)],
            [f(box(0, 0.1, 0.42, 1.6, 0.21), 3), s(poly([-0.2, 0.2, -0.6, 0.2, -0.6, -0.25], closed: false), 3, 0.2),
             s(poly([0.2, -0.05, 0.6, -0.05, 0.6, -0.5], closed: false), 3, 0.2), f(box(0, 0.88, 0.7, 0.3, 0.06), 2)],
            [f(box(0, 0.1, 1.0, 1.3, 0.12), 2), s(poly([-0.35, -0.55, -0.35, -0.85, 0.1, -0.85, 0.1, -0.55], closed: false), 2, 0.12),
             f(poly([0.3, -0.5, 0.55, -0.9, 0.75, -0.8, 0.6, -0.5]), 2),
             s(poly([-0.3, -0.2, 0.3, 0.5], closed: false), -2, 0.12), s(poly([0.3, -0.2, -0.3, 0.5], closed: false), -2, 0.12)]
        ]
    }

    private static func ocean() -> [[Layer]] {
        var wave = Path()
        wave.move(to: CGPoint(x: -0.95, y: 0.65))
        wave.addCurve(to: CGPoint(x: 0.15, y: -0.85), control1: CGPoint(x: -0.95, y: -0.1), control2: CGPoint(x: -0.4, y: -0.85))
        wave.addCurve(to: CGPoint(x: 0.7, y: -0.2), control1: CGPoint(x: 0.6, y: -0.9), control2: CGPoint(x: 0.9, y: -0.55))
        wave.addQuadCurve(to: CGPoint(x: 0.3, y: -0.4), control: CGPoint(x: 0.6, y: -0.5))
        wave.addQuadCurve(to: CGPoint(x: 0.4, y: 0.2), control: CGPoint(x: 0.1, y: -0.1))
        wave.addLine(to: CGPoint(x: 0.95, y: 0.65))
        wave.closeSubpath()
        var ribs = Path()
        for k in 1...5 {
            let a = 180 + Double(k) * 30
            ribs.move(to: CGPoint(x: 0, y: 0.35))
            ribs.addLine(to: CGPoint(x: 0.85 * CGFloat(cos(a * .pi / 180)), y: 0.35 + 0.85 * CGFloat(sin(a * .pi / 180))))
        }
        return [
            [f(wave, 0), s(poly([-0.75, 0.4, -0.3, 0.25, 0.1, 0.4, 0.55, 0.28, 0.85, 0.42], closed: false), -2, 0.1)],
            [f(arc(0, 0.35, 0.9, 180, 360, close: true), 1), f(box(0, 0.5, 0.45, 0.3, 0.1), 1), s(ribs, -2, 0.07)],
            [f(oval(-0.1, 0, 0.7, 0.45), 3), f(poly([0.5, 0, 0.95, -0.4, 0.95, 0.4]), 3), f(poly([-0.1, -0.4, 0.1, -0.78, 0.3, -0.38]), 4),
             f(disc(-0.5, -0.1, 0.09), -2), f(disc(-0.5, -0.1, 0.045), -1), s(poly([0.1, -0.35, 0.1, 0.35], closed: false), -2, 0.08)],
            [s(disc(0, -0.72, 0.17), 4, 0.1), s(poly([0, -0.55, 0, 0.8], closed: false), 4, 0.14), s(poly([-0.4, -0.3, 0.4, -0.3], closed: false), 4, 0.14),
             s(arc(0, 0.1, 0.75, 20, 160), 4, 0.14)],
            [f(poly([-0.3, 0.9, -0.2, -0.5, 0.2, -0.5, 0.3, 0.9]), -2), f(poly([-0.27, 0.35, -0.24, 0.0, 0.24, 0.0, 0.27, 0.35]), 1),
             f(box(0, -0.55, 0.6, 0.1), 4), f(box(0, -0.75, 0.3, 0.25), 2), f(poly([-0.25, -0.88, 0, -1.08, 0.25, -0.88]), 4),
             f(box(0, 0.93, 0.8, 0.14, 0.05), 4)],
            [f(star(5, 1, 0.5), 1), f(disc(0, 0, 0.1), 2), f(disc(0, -0.5, 0.06), 2), f(disc(0.45, -0.15, 0.06), 2),
             f(disc(0.28, 0.4, 0.06), 2), f(disc(-0.28, 0.4, 0.06), 2), f(disc(-0.45, -0.15, 0.06), 2)]
        ]
    }

    private static func jungle() -> [[Layer]] {
        var banana = Path()
        banana.move(to: CGPoint(x: -0.85, y: -0.3))
        banana.addQuadCurve(to: CGPoint(x: 0.85, y: -0.6), control: CGPoint(x: 0, y: 1.2))
        banana.addQuadCurve(to: CGPoint(x: -0.85, y: -0.3), control: CGPoint(x: 0, y: 0.45))
        var beak = Path()
        beak.move(to: CGPoint(x: -0.1, y: -0.6))
        beak.addQuadCurve(to: CGPoint(x: 0.95, y: 0.1), control: CGPoint(x: 0.8, y: -0.7))
        beak.addQuadCurve(to: CGPoint(x: -0.1, y: 0.25), control: CGPoint(x: 0.5, y: 0.5))
        beak.closeSubpath()
        var petals = Path()
        for k in 0..<5 {
            let a = Double(k) * 2 * .pi / 5 - .pi / 2
            petals.addPath(disc(0.55 * CGFloat(cos(a)), 0.55 * CGFloat(sin(a)), 0.4))
        }
        return [
            [s(poly([0, 0.2, 0, 1], closed: false), 1, 0.12), f(disc(0, -0.05, 0.9), 0), f(poly([-1, -0.35, -0.35, -0.05, -1, 0.05]), -3),
             f(poly([1, -0.35, 0.35, -0.05, 1, 0.05]), -3), f(poly([-0.95, 0.35, -0.3, 0.2, -0.75, 0.6]), -3),
             f(poly([0.95, 0.35, 0.3, 0.2, 0.75, 0.6]), -3), s(poly([0, 0.7, 0, -0.8], closed: false), 1, 0.07)],
            [f(poly([-0.2, 0.7, -0.5, 1.1, 0.05, 1.05, 0.2, 0.7]), 2), f(oval(0, 0.1, 0.55, 0.8), 3), f(oval(-0.18, 0.2, 0.3, 0.5), 4),
             f(disc(0.15, -0.65, 0.36), 3), f(poly([0.45, -0.72, 0.85, -0.55, 0.45, -0.42]), 2), f(disc(0.22, -0.72, 0.09), -2),
             f(disc(0.24, -0.72, 0.04), -1)],
            [f(banana, 2), f(disc(-0.85, -0.3, 0.07), -1), f(disc(0.85, -0.6, 0.07), -1)],
            [f(disc(-0.4, 0, 0.6), -1), f(disc(-0.35, 0.12, 0.3), -2), f(beak, 2), s(poly([0, -0.2, 0.9, 0.0], closed: false), 3, 0.1),
             f(disc(-0.3, -0.2, 0.12), -2), f(disc(-0.28, -0.2, 0.06), -1)],
            [f(petals, 3), f(disc(0, 0, 0.6), 3), f(disc(0, 0, 0.3), 2)],
            [f(poly([-0.4, -0.3, -0.3, -0.95, -0.1, -0.45]), 0), f(poly([-0.1, -0.4, 0, -1.05, 0.1, -0.4]), 0),
             f(poly([0.1, -0.45, 0.3, -0.95, 0.4, -0.3]), 0), f(oval(0, 0.3, 0.5, 0.68), 2),
             s(poly([-0.35, 0, 0.35, 0.7, -0.4, 0.35, 0.4, 0.05, -0.1, -0.2, 0.1, 0.95], closed: false), 3, 0.06)]
        ]
    }

    private static func streetFood() -> [[Layer]] {
        var noodles = Path()
        for k in 0..<4 {
            let y = -0.35 + CGFloat(k) * 0.12
            noodles.move(to: CGPoint(x: -0.7, y: y))
            noodles.addQuadCurve(to: CGPoint(x: 0, y: y), control: CGPoint(x: -0.35, y: y - 0.25))
            noodles.addQuadCurve(to: CGPoint(x: 0.7, y: y), control: CGPoint(x: 0.35, y: y + 0.25))
        }
        var chilli = Path()
        chilli.move(to: CGPoint(x: -0.7, y: -0.7))
        chilli.addQuadCurve(to: CGPoint(x: 0.9, y: 0.9), control: CGPoint(x: 0.6, y: -0.8))
        chilli.addQuadCurve(to: CGPoint(x: -0.7, y: -0.7), control: CGPoint(x: -0.2, y: 0.5))
        var steam = Path()
        steam.move(to: CGPoint(x: -0.15, y: -0.55))
        steam.addQuadCurve(to: CGPoint(x: -0.15, y: -0.95), control: CGPoint(x: -0.4, y: -0.75))
        steam.move(to: CGPoint(x: 0.2, y: -0.55))
        steam.addQuadCurve(to: CGPoint(x: 0.2, y: -0.95), control: CGPoint(x: -0.05, y: -0.75))
        return [
            [f(disc(-0.6, -0.12, 0.22), 3), f(disc(-0.2, -0.28, 0.25), 1), f(disc(0.25, -0.25, 0.25), 3), f(disc(0.65, -0.12, 0.2), 1),
             f(arc(0, -0.1, 0.95, 0, 180, close: true), 2), s(arc(0, -0.1, 0.7, 30, 150), 0, 0.07)],
            [f(oval(0, -0.1, 0.8, 0.45), 2), s(noodles, 0, 0.05), s(poly([0.2, -0.2, 0.8, -0.95], closed: false), 4, 0.07),
             s(poly([0.35, -0.2, 0.95, -0.8], closed: false), 4, 0.07), f(arc(0, 0, 0.9, 0, 180, close: true), 1)],
            [f(poly([-0.55, -0.4, 0.55, -0.4, 0.4, 0.8, -0.4, 0.8]), 0), s(arc(0.55, 0.15, 0.3, 270, 450), 0, 0.1),
             f(oval(0, -0.4, 0.55, 0.12), 4), s(steam, 4, 0.07)],
            [f(arc(0, 0.35, 0.9, 180, 360, close: true), 2), f(box(0, 0.4, 1.8, 0.1, 0.05), 2),
             s(poly([-0.4, -0.3, -0.3, -0.05, -0.1, -0.5, -0.05, -0.05, 0.15, -0.55, 0.2, -0.05, 0.4, -0.4, 0.45, -0.05], closed: false), 4, 0.05)],
            [f(chilli, 1), f(poly([-0.7, -0.7, -0.95, -0.95, -0.5, -0.85]), 3)],
            [f(box(0, 0.8, 0.18, 0.5), 4), f(box(0, -0.15, 0.8, 1.3, 0.4), 1), s(poly([-0.2, -0.5, -0.2, -0.1], closed: false), -2, 0.1)]
        ]
    }

    private static func retroTech() -> [[Layer]] {
        let heart = ["-XX-XX-", "XXXXXXX", "XXXXXXX", "-XXXXX-", "--XXX--", "---X---"]
        var pixels = Path()
        for (row, line) in heart.enumerated() {
            for (col, ch) in line.enumerated() where ch == "X" {
                pixels.addRect(CGRect(x: -0.98 + CGFloat(col) * 0.28, y: -0.84 + CGFloat(row) * 0.28, width: 0.28, height: 0.28))
            }
        }
        return [
            [f(box(0, 0, 1.7, 1.7, 0.1), 0), f(box(0.15, -0.65, 0.9, 0.5, 0.04), 4), f(box(0.35, -0.65, 0.16, 0.3), -2),
             f(box(0, 0.5, 1.2, 0.7, 0.05), -2), s(poly([-0.4, 0.35, 0.4, 0.35], closed: false), 4, 0.06),
             s(poly([-0.4, 0.6, 0.2, 0.6], closed: false), 4, 0.06)],
            [f(box(0, 0, 1.9, 1.2, 0.12), 1), f(box(0, -0.15, 1.5, 0.6, 0.06), -2), f(disc(-0.4, -0.15, 0.18), 4),
             f(disc(0.4, -0.15, 0.18), 4), f(box(0, 0.5, 0.9, 0.3, 0.1), 4)],
            [f(box(0, 0.65, 1.5, 0.5, 0.15), 3), s(poly([0, 0.5, 0, -0.3], closed: false), 4, 0.16), f(disc(0, -0.5, 0.38), 1),
             f(disc(-0.5, 0.62, 0.1), 2), f(disc(0.5, 0.62, 0.1), 2)],
            [f(box(0, 0.8, 1.0, 0.2, 0.06), 0), f(box(0, -0.05, 1.8, 1.4, 0.25), 0), f(box(-0.1, -0.05, 1.3, 1.0, 0.2), -1),
             s(poly([-0.6, -0.25, -0.35, -0.05, -0.6, 0.15], closed: false), 2, 0.07), s(poly([-0.25, 0.2, 0.05, 0.2], closed: false), 2, 0.07),
             f(disc(0.75, -0.3, 0.1), 2), f(disc(0.75, 0, 0.1), 2)],
            [f(pixels, 1), f(Path(CGRect(x: -0.7, y: -0.7, width: 0.28, height: 0.28)), -2)],
            [f(box(0, 0, 1.8, 0.9, 0.4), 3), s(poly([-0.6, 0, -0.2, 0], closed: false), 4, 0.12), s(poly([-0.4, -0.2, -0.4, 0.2], closed: false), 4, 0.12),
             f(disc(0.3, 0.1, 0.12), 1), f(disc(0.6, -0.1, 0.12), 2)]
        ]
    }

    private static func weather() -> [[Layer]] {
        var flake = Path()
        for k in 0..<6 {
            let a = Double(k) * .pi / 3
            let (c, sn) = (CGFloat(cos(a)), CGFloat(sin(a)))
            flake.move(to: .zero)
            flake.addLine(to: CGPoint(x: 0.95 * c, y: 0.95 * sn))
            for side in [CGFloat(-1), 1] {
                let b = a + Double(side) * .pi / 5
                flake.move(to: CGPoint(x: 0.6 * c, y: 0.6 * sn))
                flake.addLine(to: CGPoint(x: 0.6 * c + 0.3 * CGFloat(cos(b)), y: 0.6 * sn + 0.3 * CGFloat(sin(b))))
            }
        }
        var cloudP = Path()
        cloudP.addPath(disc(-0.5, 0.1, 0.42))
        cloudP.addPath(disc(0, -0.2, 0.55))
        cloudP.addPath(disc(0.5, 0.1, 0.42))
        cloudP.addRoundedRect(in: CGRect(x: -0.92, y: 0.1, width: 1.84, height: 0.52), cornerSize: CGSize(width: 0.26, height: 0.26))
        return [
            [f(cloudP, 0)],
            [f(poly([0.15, -1, -0.6, 0.15, -0.1, 0.15, -0.3, 1, 0.6, -0.2, 0.05, -0.2]), 1)],
            [s(arc(0, 0.5, 0.9, 180, 360), 3, 0.2), s(arc(0, 0.5, 0.7, 180, 360), 1, 0.2), s(arc(0, 0.5, 0.5, 180, 360), 0, 0.2),
             f(oval(-0.8, 0.5, 0.2, 0.14), -2), f(oval(0.8, 0.5, 0.2, 0.14), -2)],
            [f(arc(0, 0, 0.95, 180, 360, close: true), 3), s(poly([0, -0.95, -0.35, 0], closed: false), -2, 0.06),
             s(poly([0, -0.95, 0.35, 0], closed: false), -2, 0.06), s(poly([0, 0, 0, 0.7], closed: false), 4, 0.1),
             s(arc(-0.2, 0.7, 0.2, 0, 180), 4, 0.1)],
            [s(flake, 0, 0.12)],
            [f(disc(0, 0, 0.5), 1), s(rays(8, 0.7, 0.97), 1, 0.15)]
        ]
    }

    private static func music() -> [[Layer]] {
        var mic = Path()
        mic.addPath(disc(0, -0.4, 0.4))
        var grid = Path()
        grid.move(to: CGPoint(x: -0.35, y: -0.4)); grid.addLine(to: CGPoint(x: 0.35, y: -0.4))
        grid.move(to: CGPoint(x: 0, y: -0.78)); grid.addLine(to: CGPoint(x: 0, y: -0.02))
        var pick = Path()
        pick.move(to: CGPoint(x: 0, y: 0.95))
        pick.addCurve(to: CGPoint(x: -0.85, y: -0.55), control1: CGPoint(x: -0.5, y: 0.55), control2: CGPoint(x: -0.9, y: 0))
        pick.addQuadCurve(to: CGPoint(x: 0.85, y: -0.55), control: CGPoint(x: 0, y: -1))
        pick.addCurve(to: CGPoint(x: 0, y: 0.95), control1: CGPoint(x: 0.9, y: 0), control2: CGPoint(x: 0.5, y: 0.55))
        pick.closeSubpath()
        return [
            [f(disc(0, 0, 0.95), 4), s(disc(0, 0, 0.72), 1, 0.04), s(disc(0, 0, 0.58), 1, 0.04), f(disc(0, 0, 0.35), 0), f(disc(0, 0, 0.06), -3)],
            [s(arc(0, 0.05, 0.75, 180, 360), 1, 0.14), f(box(-0.78, 0.25, 0.4, 0.65, 0.15), 0), f(box(0.78, 0.25, 0.4, 0.65, 0.15), 0)],
            [s(poly([-0.22, 0.6, -0.22, -0.6], closed: false), 1, 0.1), s(poly([0.68, 0.4, 0.68, -0.8], closed: false), 1, 0.1),
             f(poly([-0.22, -0.6, 0.68, -0.8, 0.68, -0.55, -0.22, -0.35]), 1), f(disc(-0.45, 0.6, 0.25), 1), f(disc(0.45, 0.4, 0.25), 1)],
            [f(box(0, 0, 1.2, 1.8, 0.15), 4), f(disc(0, 0.35, 0.42), 0), f(disc(0, 0.35, 0.15), 2), f(disc(0, -0.5, 0.2), 0)],
            [f(pick, 2), s(arc(0, -0.1, 0.5, 200, 280), -2, 0.08)],
            [f(poly([-0.18, -0.1, 0.18, -0.1, 0.1, 0.95, -0.1, 0.95]), 4), f(mic, 1), s(grid, -2, 0.06)]
        ]
    }

    private static func wonders() -> [[Layer]] {
        var dome = Path()
        dome.move(to: CGPoint(x: -0.45, y: 0.2))
        dome.addCurve(to: CGPoint(x: 0, y: -0.85), control1: CGPoint(x: -0.95, y: -0.2), control2: CGPoint(x: -0.2, y: -0.55))
        dome.addCurve(to: CGPoint(x: 0.45, y: 0.2), control1: CGPoint(x: 0.2, y: -0.55), control2: CGPoint(x: 0.95, y: -0.2))
        dome.closeSubpath()
        var tiers: [Layer] = []
        for k in 0..<3 {
            let kf = CGFloat(k), yb = 0.8 - kf * 0.55, sh = 0.2 * kf
            tiers.append(f(box(0, yb - 0.1, 0.8 - 0.2 * kf, 0.3), 5))
            tiers.append(f(poly([-(0.95 - sh), yb - 0.18, 0.95 - sh, yb - 0.18, 0.7 - sh, yb - 0.42, -(0.7 - sh), yb - 0.42]), 1))
        }
        tiers.append(s(poly([0, -0.75, 0, -1.02], closed: false), 4, 0.08))
        var arch = Path()
        arch.move(to: CGPoint(x: -0.95, y: 0.9)); arch.addLine(to: CGPoint(x: -0.95, y: -0.1))
        arch.addArc(center: CGPoint(x: 0, y: -0.1), radius: 0.95, startAngle: .degrees(180), endAngle: .degrees(360), clockwise: false)
        arch.addLine(to: CGPoint(x: 0.95, y: 0.9)); arch.closeSubpath()
        var opening = Path()
        opening.move(to: CGPoint(x: -0.45, y: 0.9)); opening.addLine(to: CGPoint(x: -0.45, y: 0))
        opening.addArc(center: CGPoint(x: 0, y: 0), radius: 0.45, startAngle: .degrees(180), endAngle: .degrees(360), clockwise: false)
        opening.addLine(to: CGPoint(x: 0.45, y: 0.9)); opening.closeSubpath()
        var blades = Path()
        for k in 0..<4 {
            let a = Double(k) * .pi / 2 + 0.5
            blades.move(to: CGPoint(x: 0, y: -0.25))
            blades.addLine(to: CGPoint(x: 0.9 * CGFloat(cos(a)), y: -0.25 + 0.9 * CGFloat(sin(a))))
        }
        return [
            [f(poly([-0.95, 0.7, 0, -0.8, 0.95, 0.7]), 0), f(poly([0, -0.8, 0.95, 0.7, 0.2, 0.7]), 5)],
            [f(box(-0.55, 0.15, 0.16, 1.4), 1), f(box(0.55, 0.15, 0.16, 1.4), 1), f(poly([-1, -0.6, 1, -0.6, 0.8, -0.38, -0.8, -0.38]), 1),
             f(box(0, -0.15, 1.4, 0.14), 1), f(box(0, -0.64, 2, 0.1), -1)],
            [f(box(0, 0.55, 0.6, 0.8), 0), f(dome, 2), s(poly([0, -0.85, 0, -1.08], closed: false), 1, 0.08), f(arc(0, 0.9, 0.16, 180, 360, close: true), 4)],
            [f(arch, 3), f(opening, -3), f(poly([-0.12, -1.04, 0.12, -1.04, 0.1, -0.6, -0.1, -0.6]), 0)],
            tiers,
            [f(poly([-0.3, 0.9, -0.2, -0.1, 0.2, -0.1, 0.3, 0.9]), 3), f(poly([-0.25, -0.1, 0, -0.38, 0.25, -0.1]), 1),
             s(blades, 1, 0.2), f(disc(0, -0.25, 0.1), 4)]
        ]
    }

    private static func search() -> [[Layer]] {
        return [
            [f(disc(-0.15, -0.15, 0.55), -2), s(disc(-0.15, -0.15, 0.55), 0, 0.2), s(poly([0.25, 0.25, 0.9, 0.9], closed: false), 1, 0.26),
             s(arc(-0.15, -0.15, 0.35, 200, 260), -2, 0.07)],
            [f(box(0.3, -0.3, 1.2, 1.0, 0.12), 2), f(box(-0.2, 0.15, 1.3, 1.1, 0.12), 0), f(box(-0.65, -0.55, 0.6, 0.25, 0.1), 0),
             s(poly([-0.7, 0.0, 0.1, 0.0], closed: false), -2, 0.09), s(poly([-0.7, 0.3, -0.1, 0.3], closed: false), -2, 0.09)],
            [f(poly([-0.5, -0.9, -0.5, 0.7, -0.15, 0.35, 0.15, 0.95, 0.4, 0.85, 0.1, 0.25, 0.6, 0.25]), -1)],
            [f(box(0, 0.1, 1.7, 1.6, 0.3), 5), f(box(0, -0.05, 1.7, 1.5, 0.3), -2), s(poly([0.25, -0.5, -0.25, 0.4], closed: false), -1, 0.2)],
            [f(poly([-0.55, -0.95, 0.55, -0.95, 0.55, 0.95, 0, 0.5, -0.55, 0.95]), 4), f(star(5, 0.25, 0.11, 0, -0.35), -2)],
            [f(sparkle(-0.1, -0.1, 0.9), 1), f(sparkle(0.65, 0.6, 0.35), 2)]
        ]
    }

    // MARK: scattering

    static func paint(_ context: GraphicsContext, size: CGSize, t: HomeTuning, dark: Bool) {
        let pen = Pen(dark: dark)
        let look = look(t.pack)
        let art = stickers(t.pack)
        var rng = Seeded(HomeBackground.seed("stickers." + t.pack.rawValue))
        context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(pen(look.ground)))
        let m = min(size.width, size.height)
        let area = Double(size.width * size.height) / (1200 * 800)
        let count = max(8, min(60, Int((6 + t.density * 26) * max(0.5, area))))
        let base = m * (0.04 + 0.075 * CGFloat(t.scale))
        var placed: [(CGPoint, CGFloat)] = []
        let first = Int.random(in: 0..<art.count, using: &rng)
        for i in 0..<count {
            let r = base * CGFloat.random(in: 0.85...1.2, using: &rng)
            var spot: CGPoint?
            for _ in 0..<60 {
                let c = CGPoint(x: CGFloat.random(in: 0.04...0.96, using: &rng) * size.width,
                                y: CGFloat.random(in: 0.05...0.95, using: &rng) * size.height)
                // Out of the middle, where the address field is.
                let dx = (c.x - size.width / 2) / (size.width * 0.3), dy = (c.y - size.height / 2) / (size.height * 0.25)
                if dx * dx + dy * dy < 1 { continue }
                if placed.contains(where: { hypot($0.0.x - c.x, $0.0.y - c.y) < ($0.1 + r) * 1.35 }) { continue }
                spot = c
                break
            }
            guard let c = spot else { continue }
            placed.append((c, r))
            let layers = art[(i + first) % art.count]
            let tilt = Double.random(in: -22...22, using: &rng)
            var local = context
            local.translateBy(x: c.x, y: c.y)
            local.rotate(by: .degrees(tilt))
            local.scaleBy(x: r, y: r)
            func paint(_ code: Int) -> Color {
                switch code {
                case -1: return pen((0.20, 0.18, 0.24))
                case -2: return pen((1, 1, 1))
                case -3: return pen(look.ground)
                default: return pen(look.palette[min(code, look.palette.count - 1)])
                }
            }
            // The die-cut edge and its shadow, then the layers on top.
            local.drawLayer { layer in
                // In the sticker's own units (the layer is already scaled by r): sized by r
                // again, the blur spread wide and read as a grey smudge.
                layer.addFilter(.shadow(color: .black.opacity(dark ? 0.35 : 0.14), radius: 0.04, x: 0, y: 0.03))
                for l in layers {
                    layer.stroke(l.path, with: .color(pen((1, 1, 1))),
                                 style: StrokeStyle(lineWidth: 0.34 + l.width, lineCap: .round, lineJoin: .round))
                    if l.width == 0 { layer.fill(l.path, with: .color(pen((1, 1, 1)))) }
                }
            }
            for l in layers {
                if l.width == 0 { local.fill(l.path, with: .color(paint(l.colour))) }
                else {
                    local.stroke(l.path, with: .color(paint(l.colour)),
                                 style: StrokeStyle(lineWidth: l.width, lineCap: .round, lineJoin: .round))
                }
            }
        }
    }
}
