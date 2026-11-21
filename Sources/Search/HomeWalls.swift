import SwiftUI

/// Ten scenic murals, drawn in code: layered flat silhouettes in a few tones.
/// Vector, seeded and still, so a wall is the same on every render. Each scene
/// keeps its horizon low or its detail to the edges, so the middle stays calm
/// for the address field.
enum HomeWalls {
    static func paint(_ theme: HomeTheme, _ g: GraphicsContext, size: CGSize, dark: Bool) {
        let night: Set<HomeTheme> = [.northernLights, .saturnRise, .moonscape, .cityAtNight]
        let s = Scene(g, size, Pen(dark: dark, night: night.contains(theme)),
                      seed: HomeBackground.seed(theme.rawValue))
        switch theme {
        case .openRoad: s.openRoad()
        case .desertHighway: s.desertHighway()
        case .coastalCliffs: s.coastalCliffs()
        case .mountainLake: s.mountainLake()
        case .riceTerraces: s.riceTerraces()
        case .northernLights: s.northernLights()
        case .saturnRise: s.saturnRise()
        case .moonscape: s.moonscape()
        case .cityAtNight: s.cityAtNight()
        case .monsoonForest: s.monsoonForest()
        default: return
        }
        s.grain()
    }
}

/// One canvas with its pen and generator. Coordinates are fractions of the
/// width and height unless a name says otherwise.
private final class Scene {
    let g: GraphicsContext
    let w: CGFloat, h: CGFloat
    let pen: Pen
    var rng: Seeded

    init(_ g: GraphicsContext, _ size: CGSize, _ pen: Pen, seed: UInt64) {
        self.g = g
        w = size.width
        h = size.height
        self.pen = pen
        rng = Seeded(seed)
    }

    // MARK: helpers

    func rand(_ range: ClosedRange<CGFloat>) -> CGFloat { CGFloat.random(in: range, using: &rng) }
    func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * w, y: y * h) }

    func poly(_ pts: [(CGFloat, CGFloat)]) -> Path {
        var p = Path()
        for (i, q) in pts.enumerated() {
            i == 0 ? p.move(to: pt(q.0, q.1)) : p.addLine(to: pt(q.0, q.1))
        }
        p.closeSubpath()
        return p
    }

    func fill(_ path: Path, _ c: RGB, _ a: Double = 1) { g.fill(path, with: .color(pen(c, a))) }

    func stroke(_ path: Path, _ c: RGB, _ width: CGFloat, _ a: Double = 1) {
        g.stroke(path, with: .color(pen(c, a)), style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
    }

    /// A disc; the radius is a fraction of the height.
    func disc(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: x * w - r * h, y: y * h - r * h, width: 2 * r * h, height: 2 * r * h))
    }

    func oval(_ x: CGFloat, _ y: CGFloat, _ rx: CGFloat, _ ry: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: (x - rx) * w, y: (y - ry) * h, width: 2 * rx * w, height: 2 * ry * h))
    }

    func rect(_ x: CGFloat, _ y: CGFloat, _ rw: CGFloat, _ rh: CGFloat) -> Path {
        Path(CGRect(x: x * w, y: y * h, width: rw * w, height: rh * h))
    }

    /// A vertical gradient across the whole canvas, evenly spaced stops.
    func sky(_ cols: [RGB], to: CGFloat = 1) {
        g.fill(Path(CGRect(x: -2, y: -2, width: w + 4, height: h + 4)),
               with: .linearGradient(Gradient(colors: cols.map { pen($0) }),
                                     startPoint: .zero, endPoint: CGPoint(x: 0, y: h * to)))
    }

    func ridgeY(_ u: CGFloat, _ base: CGFloat, _ amp: CGFloat, _ freq: CGFloat, _ phase: CGFloat) -> CGFloat {
        let a = sin(u * freq * 2 * CGFloat.pi + phase)
        let b = sin(u * freq * 5.4 * CGFloat.pi / 2 + phase * 1.7)
        return base + amp * (0.6 * a + 0.4 * b)
    }

    /// A rolling silhouette filled down to the bottom edge.
    func ridge(_ base: CGFloat, _ amp: CGFloat, _ freq: CGFloat, _ phase: CGFloat) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: -4, y: h * 1.05))
        for i in 0...64 {
            let u = CGFloat(i) / 64
            p.addLine(to: CGPoint(x: -4 + u * (w + 8), y: ridgeY(u, base, amp, freq, phase) * h))
        }
        p.addLine(to: CGPoint(x: w + 4, y: h * 1.05))
        p.closeSubpath()
        return p
    }

    func stars(_ n: Int, _ top: CGFloat, _ bottom: CGFloat) {
        let k = min(w, h) / 900
        for _ in 0..<n {
            let x = rand(0...1) * w, y = rand(top...bottom) * h
            let r = rand(0.5...1.6) * k
            fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                 (1, 1, 0.92), Double(rand(0.4...0.95)))
        }
    }

    func cloud(_ x: CGFloat, _ y: CGFloat, _ s: CGFloat, _ c: RGB, _ a: Double) {
        fill(oval(x, y, 0.07 * s, 0.022 * s), c, a)
        fill(oval(x - 0.03 * s, y - 0.016 * s, 0.04 * s, 0.022 * s), c, a)
        fill(oval(x + 0.03 * s, y - 0.012 * s, 0.045 * s, 0.02 * s), c, a)
    }

    func pine(_ x: CGFloat, _ base: CGFloat, _ height: CGFloat, _ c: RGB) {
        let tw = height * 0.16 * h / w
        fill(rect(x - tw / 2, base - height * 0.12, tw, height * 0.14), c)
        for k in 0..<3 {
            let kf = CGFloat(k)
            let top = base - height + kf * height * 0.24
            let bot = base - height * 0.1 - (2 - kf) * height * 0.2
            let half = (0.22 + 0.16 * kf) * height * h / w * 0.9
            fill(poly([(x, top), (x + half, bot), (x - half, bot)]), c)
        }
    }

    /// A little grain, cheap: a few hundred specks.
    func grain() {
        let k = max(0.7, min(w, h) / 900)
        for i in 0..<240 {
            let x = rand(0...1) * w, y = rand(0...1) * h
            let r = rand(0.4...1.0) * k
            let c: Color = i % 2 == 0 ? .black.opacity(0.035) : .white.opacity(0.05)
            g.fill(Path(ellipseIn: CGRect(x: x, y: y, width: r * 2, height: r * 2)), with: .color(c))
        }
    }

    // MARK: 1. Open Road

    func openRoad() {
        sky([(0.58, 0.78, 0.92), (0.80, 0.90, 0.94), (0.99, 0.93, 0.82)], to: 0.65)
        cloud(0.2, 0.2, 1.4, (1, 1, 1), 0.7)
        cloud(0.78, 0.14, 1.1, (1, 1, 1), 0.6)
        cloud(0.55, 0.32, 0.8, (1, 1, 1), 0.45)
        fill(ridge(0.62, 0.02, 1.3, 0.5), (0.66, 0.78, 0.68))
        fill(ridge(0.645, 0.016, 1.9, 2.0), (0.52, 0.70, 0.48))
        let hz: CGFloat = 0.65
        fill(rect(-0.01, hz, 1.02, 1 - hz + 0.02), (0.55, 0.72, 0.36))
        let vp = pt(0.5, hz)
        // Fields: stripes fanning out from the vanishing point, and bands across.
        for i in -12..<12 {
            let x0 = 0.5 + CGFloat(i) * 0.22, x1 = x0 + 0.22
            var tri = Path()
            tri.move(to: vp)
            tri.addLine(to: pt(x0 * 1.0 + (x0 - 0.5) * 3, 1.05))
            tri.addLine(to: pt(x1 + (x1 - 0.5) * 3, 1.05))
            tri.closeSubpath()
            let tones: [RGB] = [(0.62, 0.77, 0.38), (0.80, 0.74, 0.40), (0.48, 0.66, 0.34)]
            fill(tri, tones[((i % 3) + 3) % 3], i % 2 == 0 ? 0.9 : 0.5)
        }
        for k in 0..<9 {
            let t0 = pow(CGFloat(k) / 9, 2), t1 = pow((CGFloat(k) + 0.5) / 9, 2)
            fill(rect(-0.01, hz + (1 - hz) * t0, 1.02, (1 - hz) * (t1 - t0)), (1, 1, 0.8), 0.1)
        }
        // The road.
        var road = Path()
        road.move(to: CGPoint(x: vp.x - 0.004 * w, y: vp.y))
        road.addLine(to: CGPoint(x: vp.x + 0.004 * w, y: vp.y))
        road.addLine(to: pt(0.5 + 0.17, 1.02))
        road.addLine(to: pt(0.5 - 0.17, 1.02))
        road.closeSubpath()
        fill(road, (0.42, 0.42, 0.46))
        let n = 14
        for k in stride(from: 0, to: n, by: 2) {
            let t0 = pow(CGFloat(k) / CGFloat(n), 2), t1 = pow((CGFloat(k) + 1) / CGFloat(n), 2)
            let w0 = 0.002 + 0.007 * t0, w1 = 0.002 + 0.007 * t1
            let y0 = hz + (1.02 - hz) * t0, y1 = hz + (1.02 - hz) * t1
            fill(poly([(0.5 - w0, y0), (0.5 + w0, y0), (0.5 + w1, y1), (0.5 - w1, y1)]), (0.96, 0.9, 0.62))
        }
        // Telegraph poles and the wires between them.
        for side in [CGFloat(-1), 1] {
            var tops: [CGPoint] = []
            for j in 0..<7 {
                let t = pow((CGFloat(j) + 1.3) / 8.2, 1.7)
                let y = hz + (1.02 - hz) * t
                let x = 0.5 + side * (0.004 + 0.166 * t + 0.03 * t + 0.008)
                let ph = 0.2 * t
                fill(rect(x - 0.0015 - 0.002 * t, y - ph, 0.003 + 0.004 * t, ph), (0.30, 0.24, 0.22))
                fill(rect(x - 0.008 * (0.4 + t), y - ph, 0.016 * (0.4 + t), 0.004 + 0.006 * t), (0.30, 0.24, 0.22))
                tops.append(pt(x, y - ph))
            }
            for j in 0..<tops.count - 1 {
                var wire = Path()
                wire.move(to: tops[j])
                wire.addQuadCurve(to: tops[j + 1], control: CGPoint(x: (tops[j].x + tops[j + 1].x) / 2,
                                                                     y: (tops[j].y + tops[j + 1].y) / 2 + 0.012 * h))
                stroke(wire, (0.28, 0.24, 0.24), 1, 0.7)
            }
        }
    }

    // MARK: 2. Desert Highway

    private func mesa(_ cx: CGFloat, _ wd: CGFloat, _ ht: CGFloat, _ base: CGFloat) -> Path {
        let shape: [(CGFloat, CGFloat)] = [(-0.5, 0), (-0.46, -0.55), (-0.40, -0.58), (-0.38, -1), (0.30, -1),
                                           (0.33, -0.6), (0.40, -0.55), (0.5, 0)]
        return poly(shape.map { (cx + $0.0 * wd, base + $0.1 * ht) })
    }

    func desertHighway() {
        sky([(0.26, 0.18, 0.44), (0.62, 0.30, 0.50), (0.94, 0.52, 0.44), (0.99, 0.76, 0.46)], to: 0.67)
        let hz: CGFloat = 0.67
        for (k, a) in [(1.9, 0.12), (1.45, 0.2), (0.98, 0.9)] as [(CGFloat, Double)] {
            fill(disc(0.74, hz, 0.12 * k), (1, 0.82, 0.5), a)
        }
        fill(disc(0.74, hz, 0.12), (1, 0.88, 0.55))
        for (cx, wd, ht) in [(0.12, 0.2, 0.14), (0.34, 0.14, 0.09), (0.9, 0.2, 0.15), (0.64, 0.1, 0.05)] as [(CGFloat, CGFloat, CGFloat)] {
            fill(mesa(cx, wd, ht, hz + 0.01), (0.62, 0.34, 0.50))
        }
        for (cx, wd, ht) in [(0.04, 0.26, 0.2), (0.23, 0.15, 0.1), (0.97, 0.22, 0.17), (0.8, 0.12, 0.07)] as [(CGFloat, CGFloat, CGFloat)] {
            fill(mesa(cx, wd, ht, hz + 0.02), (0.74, 0.36, 0.34))
        }
        g.fill(Path(CGRect(x: -2, y: hz * h, width: w + 4, height: h)),
               with: .linearGradient(Gradient(colors: [pen((0.72, 0.36, 0.32)), pen((0.40, 0.19, 0.28))]),
                                     startPoint: CGPoint(x: 0, y: hz * h), endPoint: CGPoint(x: 0, y: h)))
        // The winding road, as a ribbon along a centre line.
        func centre(_ t: CGFloat) -> CGPoint {
            CGPoint(x: (0.5 + sin(t * CGFloat.pi * 1.6) * 0.17 * t) * w, y: (hz + (1.03 - hz) * pow(t, 1.6)) * h)
        }
        func half(_ t: CGFloat) -> CGFloat { (0.003 + 0.13 * t) * w }
        var left: [CGPoint] = [], right: [CGPoint] = []
        for i in 0...40 {
            let t = CGFloat(i) / 40, c = centre(t), hw = half(t)
            left.append(CGPoint(x: c.x - hw, y: c.y))
            right.append(CGPoint(x: c.x + hw, y: c.y))
        }
        var road = Path()
        road.move(to: left[0])
        for q in left.dropFirst() { road.addLine(to: q) }
        for q in right.reversed() { road.addLine(to: q) }
        road.closeSubpath()
        fill(road, (0.27, 0.19, 0.30))
        for k in stride(from: 1, to: 20, by: 2) {
            let t0 = CGFloat(k) / 20, t1 = (CGFloat(k) + 1) / 20
            let a = centre(t0), b = centre(t1), d0 = half(t0) * 0.07, d1 = half(t1) * 0.07
            var dash = Path()
            dash.move(to: CGPoint(x: a.x - d0, y: a.y))
            dash.addLine(to: CGPoint(x: a.x + d0, y: a.y))
            dash.addLine(to: CGPoint(x: b.x + d1, y: b.y))
            dash.addLine(to: CGPoint(x: b.x - d1, y: b.y))
            dash.closeSubpath()
            fill(dash, (0.98, 0.80, 0.50))
        }
        // Saguaro silhouettes at the edges.
        for (x, y, k) in [(0.07, 0.93, 1.0), (0.14, 0.86, 0.6), (0.92, 0.9, 0.8)] as [(CGFloat, CGFloat, CGFloat)] {
            let c: RGB = (0.20, 0.10, 0.20)
            let bw = 0.012 * k
            fill(Path(roundedRect: CGRect(x: (x - bw) * w, y: (y - 0.2 * k) * h, width: bw * 2 * w, height: 0.2 * k * h),
                      cornerRadius: bw * w), c)
            var arms = Path()
            arms.move(to: pt(x - bw, y - 0.07 * k)); arms.addLine(to: pt(x - 0.035 * k, y - 0.07 * k))
            arms.addLine(to: pt(x - 0.035 * k, y - 0.13 * k))
            arms.move(to: pt(x + bw, y - 0.1 * k)); arms.addLine(to: pt(x + 0.035 * k, y - 0.1 * k))
            arms.addLine(to: pt(x + 0.035 * k, y - 0.16 * k))
            stroke(arms, c, 0.014 * w * k)
        }
    }

    // MARK: 3. Coastal Cliffs

    /// A stepped cliff face at the left (side -1) or right (side 1) edge.
    private func cliff(_ side: CGFloat, top: CGFloat, width: CGFloat, steps: Int) -> Path {
        func x(_ f: CGFloat) -> CGFloat { side < 0 ? f : 1 - f }
        var pts: [(CGFloat, CGFloat)] = [(x(-0.02), 1.05), (x(-0.02), top), (x(width), top + 0.015)]
        for i in 1...steps {
            let f = CGFloat(i) / CGFloat(steps)
            let jitter = rand(-0.02...0.02)
            pts.append((x(width * (1 - 0.5 * f) + jitter), top + (0.94 - top) * (f - 0.5 / CGFloat(steps))))
            pts.append((x(width * (1 - 0.5 * f) - 0.015 + jitter), top + (0.94 - top) * f))
        }
        pts.append((x(0.04), 1.05))
        return poly(pts)
    }

    func coastalCliffs() {
        sky([(0.68, 0.84, 0.95), (0.88, 0.93, 0.94), (0.99, 0.92, 0.84)], to: 0.56)
        fill(disc(0.58, 0.26, 0.05), (1, 0.96, 0.84), 0.7)
        cloud(0.3, 0.16, 1.2, (1, 1, 1), 0.7)
        cloud(0.8, 0.28, 0.9, (1, 1, 1), 0.55)
        let hz: CGFloat = 0.56
        g.fill(Path(CGRect(x: -2, y: hz * h, width: w + 4, height: h)),
               with: .linearGradient(Gradient(colors: [pen((0.46, 0.72, 0.80)), pen((0.20, 0.46, 0.60))]),
                                     startPoint: CGPoint(x: 0, y: hz * h), endPoint: CGPoint(x: 0, y: h)))
        fill(ridge(0.55, 0.008, 2.2, 1.0), (0.62, 0.76, 0.78), 0.8)
        for _ in 0..<16 {
            let y = rand(0.6...0.96), x = rand(0.1...0.8), l = rand(0.03...0.1)
            fill(Path(roundedRect: CGRect(x: x * w, y: y * h, width: l * w, height: 0.003 * h + 1), cornerRadius: 2),
                 (1, 1, 1), 0.28)
        }
        // Far headlands, with the lighthouse on the right.
        fill(cliff(-1, top: 0.52, width: 0.3, steps: 4), (0.62, 0.58, 0.60))
        fill(cliff(1, top: 0.52, width: 0.27, steps: 4), (0.62, 0.58, 0.60))
        fill(rect(0.88, 0.505, 0.12, 0.02), (0.50, 0.66, 0.44))
        let lx: CGFloat = 0.9, base: CGFloat = 0.515
        fill(poly([(lx, 0.35), (0.62, 0.37), (0.62, 0.43)]), (1, 0.95, 0.65), 0.2)
        fill(poly([(lx - 0.016, base), (lx - 0.009, 0.34), (lx + 0.009, 0.34), (lx + 0.016, base)]), (0.97, 0.95, 0.92))
        fill(poly([(lx - 0.0135, 0.4), (lx - 0.0115, 0.37), (lx + 0.0115, 0.37), (lx + 0.0135, 0.4)]), (0.84, 0.30, 0.28))
        fill(poly([(lx - 0.0155, 0.465), (lx - 0.0135, 0.435), (lx + 0.0135, 0.435), (lx + 0.0155, 0.465)]), (0.84, 0.30, 0.28))
        fill(rect(lx - 0.012, 0.325, 0.024, 0.016), (1, 0.9, 0.5))
        fill(poly([(lx - 0.013, 0.325), (lx, 0.30), (lx + 0.013, 0.325)]), (0.30, 0.28, 0.34))
        // Near cliffs, grass on top.
        fill(cliff(-1, top: 0.64, width: 0.22, steps: 5), (0.46, 0.40, 0.42))
        fill(cliff(1, top: 0.7, width: 0.2, steps: 5), (0.44, 0.38, 0.41))
        fill(rect(-0.01, 0.635, 0.22, 0.016), (0.44, 0.62, 0.40))
        fill(rect(0.8, 0.695, 0.21, 0.016), (0.44, 0.62, 0.40))
        for (x, y) in [(0.2, 0.9), (0.12, 0.96), (0.84, 0.92), (0.92, 0.97)] as [(CGFloat, CGFloat)] {
            fill(oval(x, y, 0.05, 0.012), (1, 1, 1), 0.5)
        }
    }

    // MARK: 4. Mountain Lake

    private func peak(_ cx: CGFloat, _ wd: CGFloat, _ ph: CGFloat, _ wh: CGFloat) -> Path {
        poly([(cx - wd, wh), (cx - wd * 0.4, wh - ph * 0.62), (cx - wd * 0.12, wh - ph * 0.78), (cx, wh - ph),
              (cx + wd * 0.2, wh - ph * 0.72), (cx + wd * 0.5, wh - ph * 0.5), (cx + wd, wh)])
    }

    private func cap(_ cx: CGFloat, _ wd: CGFloat, _ ph: CGFloat, _ wh: CGFloat) -> Path {
        poly([(cx - wd * 0.3, wh - ph * 0.64), (cx - wd * 0.12, wh - ph * 0.78), (cx, wh - ph),
              (cx + wd * 0.2, wh - ph * 0.72), (cx + wd * 0.28, wh - ph * 0.62), (cx + wd * 0.12, wh - ph * 0.68),
              (cx, wh - ph * 0.6), (cx - wd * 0.1, wh - ph * 0.68)])
    }

    func mountainLake() {
        let wh: CGFloat = 0.62
        sky([(0.72, 0.80, 0.95), (0.97, 0.86, 0.82), (0.99, 0.90, 0.78)], to: wh)
        let far: [(CGFloat, CGFloat, CGFloat)] = [(0.14, 0.3, 0.3), (0.45, 0.28, 0.15), (0.8, 0.32, 0.3)]
        let near: [(CGFloat, CGFloat, CGFloat)] = [(0.03, 0.28, 0.34), (0.3, 0.24, 0.2), (0.7, 0.22, 0.17), (0.96, 0.3, 0.4)]
        let farC: RGB = (0.62, 0.68, 0.84), nearC: RGB = (0.38, 0.48, 0.64)
        for p in far { fill(peak(p.0, p.1, p.2, wh), farC) }
        for p in far { fill(cap(p.0, p.1, p.2, wh), (0.96, 0.96, 1)) }
        for p in near { fill(peak(p.0, p.1, p.2, wh), nearC) }
        for p in near { fill(cap(p.0, p.1, p.2, wh), (1, 1, 1)) }
        // Still water, with the peaks upside down in it.
        g.fill(Path(CGRect(x: -2, y: wh * h, width: w + 4, height: h)),
               with: .linearGradient(Gradient(colors: [pen((0.58, 0.72, 0.82)), pen((0.32, 0.50, 0.64))]),
                                     startPoint: CGPoint(x: 0, y: wh * h), endPoint: CGPoint(x: 0, y: h)))
        var mirror = g
        mirror.clip(to: Path(CGRect(x: 0, y: wh * h, width: w, height: h)))
        mirror.translateBy(x: 0, y: 2 * wh * h)
        mirror.scaleBy(x: 1, y: -1)
        for p in far { mirror.fill(peak(p.0, p.1, p.2, wh), with: .color(pen(farC, 0.45))) }
        for p in near { mirror.fill(peak(p.0, p.1, p.2, wh), with: .color(pen(nearC, 0.5))) }
        for p in near { mirror.fill(cap(p.0, p.1, p.2, wh), with: .color(pen((1, 1, 1), 0.3))) }
        for _ in 0..<14 {
            let y = rand(wh + 0.03...0.95), x = rand(0.1...0.8), l = rand(0.04...0.12)
            fill(Path(roundedRect: CGRect(x: x * w, y: y * h, width: l * w, height: 0.003 * h + 1), cornerRadius: 2),
                 (1, 1, 1), 0.3)
        }
        // Shore and pines at the edges.
        let shore: RGB = (0.20, 0.34, 0.30)
        fill(ridge(0.94, 0.02, 1.4, 0.3), shore)
        for (x, hgt, b) in [(0.03, 0.34, 0.95), (0.09, 0.26, 0.96), (0.16, 0.2, 0.94), (0.22, 0.1, 0.9),
                            (0.97, 0.36, 0.95), (0.9, 0.28, 0.96), (0.83, 0.2, 0.94), (0.77, 0.09, 0.9)] as [(CGFloat, CGFloat, CGFloat)] {
            pine(x, b, hgt, shore)
        }
        pine(0.04, 0.66, 0.1, (0.28, 0.40, 0.38))
        pine(0.95, 0.66, 0.09, (0.28, 0.40, 0.38))
    }

    // MARK: 5. Rice Terraces

    func riceTerraces() {
        sky([(0.84, 0.92, 0.90), (0.97, 0.95, 0.88)], to: 0.5)
        fill(ridge(0.30, 0.05, 1.1, 0.4), (0.74, 0.84, 0.82))
        fill(ridge(0.37, 0.05, 1.6, 2.2), (0.64, 0.78, 0.74))
        fill(ridge(0.43, 0.04, 2.1, 4.1), (0.54, 0.72, 0.62))
        g.fill(Path(CGRect(x: 0, y: 0.3 * h, width: w, height: 0.24 * h)),
               with: .linearGradient(Gradient(colors: [pen((1, 1, 0.97), 0), pen((1, 1, 0.97), 0.5), pen((1, 1, 0.97), 0)]),
                                     startPoint: CGPoint(x: 0, y: 0.3 * h), endPoint: CGPoint(x: 0, y: 0.54 * h)))
        let greens: [RGB] = [(0.50, 0.70, 0.40), (0.62, 0.78, 0.46), (0.42, 0.62, 0.38), (0.70, 0.80, 0.50)]
        for k in 0..<10 {
            let kf = CGFloat(k)
            let base = 0.5 + kf * 0.058, amp = 0.012 + 0.004 * kf
            let path = ridge(base, amp, 0.9 + 0.2 * CGFloat(k % 3), kf * 1.3)
            fill(path, greens[k % 4])
            stroke(path, (0.86, 0.94, 0.80), 1.6, 0.6)
        }
        g.fill(Path(CGRect(x: 0, y: 0.46 * h, width: w, height: 0.14 * h)),
               with: .linearGradient(Gradient(colors: [pen((1, 1, 0.97), 0), pen((1, 1, 0.97), 0.28), pen((1, 1, 0.97), 0)]),
                                     startPoint: CGPoint(x: 0, y: 0.46 * h), endPoint: CGPoint(x: 0, y: 0.6 * h)))
    }

    // MARK: 6. Northern Lights

    func northernLights() {
        sky([(0.02, 0.05, 0.15), (0.05, 0.14, 0.26), (0.08, 0.24, 0.32)], to: 0.8)
        stars(130, 0.0, 0.6)
        let ribbons: [(CGFloat, CGFloat, CGFloat, CGFloat, RGB)] = [
            (0.16, 0.1, 1.3, 0.4, (0.35, 0.95, 0.65)), (0.26, 0.12, 1.7, 2.3, (0.30, 0.85, 0.85)),
            (0.12, 0.08, 2.1, 4.4, (0.55, 0.45, 0.92)), (0.32, 0.09, 1.2, 1.1, (0.40, 0.92, 0.55))]
        let k = min(w, h) * 0.014
        g.drawLayer { l in
            l.addFilter(.blur(radius: k))
            for (y0, ht, f, ph, c) in ribbons {
                var p = Path()
                for i in 0...60 {
                    let u = CGFloat(i) / 60
                    let y = (y0 + 0.07 * sin(u * f * 2 * CGFloat.pi + ph)) * self.h
                    i == 0 ? p.move(to: CGPoint(x: u * self.w, y: y)) : p.addLine(to: CGPoint(x: u * self.w, y: y))
                }
                for i in stride(from: 60, through: 0, by: -1) {
                    let u = CGFloat(i) / 60
                    let top = y0 + 0.07 * sin(u * f * 2 * CGFloat.pi + ph)
                    p.addLine(to: CGPoint(x: u * self.w, y: (top + ht * (0.7 + 0.3 * sin(u * 9 + ph))) * self.h))
                }
                p.closeSubpath()
                l.fill(p, with: .linearGradient(
                    Gradient(colors: [self.pen(c, 0.0), self.pen(c, 0.6), self.pen((0.3, 0.8, 0.7), 0)]),
                    startPoint: CGPoint(x: 0, y: (y0 - 0.07) * self.h), endPoint: CGPoint(x: 0, y: (y0 + ht + 0.07) * self.h)))
            }
        }
        fill(ridge(0.68, 0.05, 1.2, 1.0), (0.30, 0.40, 0.56))
        fill(ridge(0.79, 0.035, 1.7, 3.2), (0.72, 0.80, 0.92))
        // The cabin on the near ridge.
        let cx: CGFloat = 0.8, cy = ridgeY(0.8, 0.79, 0.035, 1.7, 3.2)
        fill(rect(cx - 0.028, cy - 0.05, 0.056, 0.058), (0.30, 0.20, 0.20))
        fill(poly([(cx - 0.036, cy - 0.048), (cx, cy - 0.095), (cx + 0.036, cy - 0.048)]), (0.20, 0.14, 0.16))
        fill(rect(cx + 0.012, cy - 0.095, 0.01, 0.03), (0.20, 0.14, 0.16))
        fill(disc(cx - 0.005, cy - 0.028, 0.026), (1, 0.85, 0.4), 0.25)
        fill(rect(cx - 0.014, cy - 0.036, 0.018, 0.02), (1, 0.85, 0.45))
        pine(cx - 0.07, cy + 0.01, 0.1, (0.14, 0.22, 0.26))
        pine(cx + 0.075, cy + 0.01, 0.13, (0.14, 0.22, 0.26))
        fill(ridge(0.92, 0.025, 1.3, 5.0), (0.86, 0.92, 1))
    }

    // MARK: 7. Saturn Rise

    private func ringPath(_ front: Bool, _ c: CGPoint, _ rx: CGFloat, _ ry: CGFloat, _ tilt: CGFloat) -> Path {
        var arc = Path()
        arc.addArc(center: .zero, radius: 1, startAngle: .degrees(front ? 0 : 180),
                   endAngle: .degrees(front ? 180 : 360), clockwise: false)
        let t = CGAffineTransform(translationX: c.x, y: c.y).rotated(by: tilt).scaledBy(x: rx, y: ry)
        return arc.applying(t)
    }

    func saturnRise() {
        sky([(0.04, 0.03, 0.14), (0.20, 0.10, 0.30), (0.52, 0.24, 0.36)], to: 0.82)
        stars(170, 0.0, 0.75)
        // A small far moon.
        fill(disc(0.16, 0.24, 0.035), (0.72, 0.68, 0.76))
        fill(disc(0.15, 0.235, 0.008), (0.55, 0.52, 0.6), 0.8)
        let c = pt(0.7, 0.66), r = 0.2 * h, tilt: CGFloat = -0.3
        let ringW = r * 0.1
        stroke(ringPath(false, c, r * 2.1, r * 0.5, tilt), (0.92, 0.82, 0.64), ringW)
        stroke(ringPath(false, c, r * 1.7, r * 0.4, tilt), (0.80, 0.68, 0.52), ringW * 0.5)
        fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)), (0.94, 0.80, 0.56))
        var body = g
        body.clip(to: Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)))
        let offsets: [CGFloat] = [-0.6, -0.25, 0.05, 0.4]
        for (i, f) in offsets.enumerated() {
            body.fill(Path(CGRect(x: c.x - r, y: c.y + f * r, width: 2 * r, height: r * (i % 2 == 0 ? 0.2 : 0.12))),
                      with: .color(pen((0.78, 0.54, 0.38), 0.45)))
        }
        body.fill(Path(ellipseIn: CGRect(x: c.x - r * 1.45, y: c.y - r * 1.1, width: 2 * r, height: 2 * r)),
                  with: .color(pen((0.2, 0.08, 0.2), 0.35)))
        stroke(ringPath(true, c, r * 2.1, r * 0.5, tilt), (0.92, 0.82, 0.64), ringW)
        stroke(ringPath(true, c, r * 1.7, r * 0.4, tilt), (0.80, 0.68, 0.52), ringW * 0.5)
        // Rocky horizon.
        fill(ridge(0.8, 0.03, 2.4, 0.7), (0.30, 0.14, 0.30))
        for _ in 0..<14 {
            let x = rand(0.0...1.0), y = ridgeY(x, 0.8, 0.03, 2.4, 0.7), s = rand(0.012...0.03)
            fill(poly([(x - s, y + 0.01), (x - s * 0.3, y - s * 1.6), (x + s * 0.5, y - s), (x + s, y + 0.01)]), (0.30, 0.14, 0.30))
        }
        fill(ridge(0.9, 0.025, 1.6, 2.5), (0.15, 0.07, 0.20))
        for _ in 0..<10 {
            let x = rand(0.0...1.0), y = ridgeY(x, 0.9, 0.025, 1.6, 2.5), s = rand(0.015...0.04)
            fill(poly([(x - s, y + 0.01), (x - s * 0.5, y - s * 1.2), (x + s * 0.3, y - s * 1.5), (x + s, y + 0.01)]), (0.15, 0.07, 0.20))
        }
    }

    // MARK: 8. Moonscape

    func moonscape() {
        sky([(0.02, 0.03, 0.09), (0.07, 0.08, 0.18), (0.14, 0.14, 0.24)], to: 0.72)
        stars(160, 0.0, 0.66)
        let c = pt(0.78, 0.27), r = 0.09 * h
        let earth = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
        stroke(Path(ellipseIn: CGRect(x: c.x - r * 1.08, y: c.y - r * 1.08, width: 2.16 * r, height: 2.16 * r)),
               (0.55, 0.75, 1), 2, 0.4)
        fill(earth, (0.22, 0.46, 0.84))
        var e = g
        e.clip(to: earth)
        for (dx, dy, sx, sy) in [(-0.3, -0.2, 0.5, 0.35), (0.35, 0.25, 0.4, 0.5), (-0.1, 0.45, 0.3, 0.2)] as [(CGFloat, CGFloat, CGFloat, CGFloat)] {
            e.fill(Path(ellipseIn: CGRect(x: c.x + (dx - sx / 2) * r, y: c.y + (dy - sy / 2) * r, width: sx * r, height: sy * r)),
                   with: .color(pen((0.40, 0.68, 0.40))))
        }
        for (dx, dy) in [(-0.1, -0.5), (0.3, 0.0), (-0.4, 0.3)] as [(CGFloat, CGFloat)] {
            e.fill(Path(ellipseIn: CGRect(x: c.x + dx * r - 0.4 * r, y: c.y + dy * r - 0.1 * r, width: 0.8 * r, height: 0.2 * r)),
                   with: .color(pen((1, 1, 1), 0.55)))
        }
        e.fill(Path(ellipseIn: CGRect(x: c.x - r * 1.5, y: c.y - r * 0.8, width: 2 * r, height: 2 * r)),
               with: .color(pen((0.02, 0.03, 0.1), 0.45)))
        fill(ridge(0.68, 0.012, 2.6, 0.5), (0.46, 0.46, 0.52))
        g.fill(ridge(0.73, 0.014, 1.5, 2.2),
               with: .linearGradient(Gradient(colors: [pen((0.70, 0.70, 0.74)), pen((0.50, 0.50, 0.56))]),
                                     startPoint: CGPoint(x: 0, y: 0.73 * h), endPoint: CGPoint(x: 0, y: h)))
        for _ in 0..<26 {
            let x = rand(0.02...0.98), y = rand(0.76...0.98)
            if abs(x - 0.5) < 0.2 && y < 0.86 { continue }
            let rx = rand(0.025...0.08) * (0.6 + (y - 0.75)), ry = rx * w / h * 0.22
            fill(oval(x, y, rx, ry), (0.40, 0.40, 0.46), 0.8)
            fill(oval(x, y + ry * 0.18, rx * 0.88, ry * 0.8), (0.50, 0.50, 0.56), 0.7)
            stroke(oval(x, y, rx, ry), (0.84, 0.84, 0.88), 1.2, 0.5)
        }
    }

    // MARK: 9. City at Night

    func cityAtNight() {
        sky([(0.08, 0.08, 0.28), (0.34, 0.20, 0.50), (0.80, 0.46, 0.52), (0.98, 0.66, 0.50)], to: 0.86)
        stars(70, 0.0, 0.45)
        let mc = pt(0.78, 0.2), mr = 0.06 * h
        fill(Path(ellipseIn: CGRect(x: mc.x - mr * 2.2, y: mc.y - mr * 2.2, width: mr * 4.4, height: mr * 4.4)),
             (1, 0.95, 0.7), 0.1)
        var moon = g
        moon.clip(to: Path(ellipseIn: CGRect(x: mc.x - mr * 0.55, y: mc.y - mr * 1.2, width: mr * 2, height: mr * 2)),
                  options: .inverse)
        moon.fill(Path(ellipseIn: CGRect(x: mc.x - mr, y: mc.y - mr, width: mr * 2, height: mr * 2)),
                  with: .color(pen((1, 0.95, 0.72))))
        let layers: [(CGFloat, CGFloat, RGB, Bool)] = [
            (0.84, 0.0, (0.34, 0.26, 0.54), false), (0.90, 0.0, (0.20, 0.16, 0.38), true), (1.0, 0.0, (0.10, 0.08, 0.22), true)]
        for (li, layer) in layers.enumerated() {
            var x: CGFloat = -0.01
            while x < 1.01 {
                let bw = rand(0.03...0.065)
                let edge = abs(x + bw / 2 - 0.5) * 2
                let ht = (0.05 + rand(0.0...0.05)) + (0.05 + rand(0.0...0.2)) * edge * edge * (1.2 - CGFloat(li) * 0.2)
                let top = layer.0 - ht
                fill(rect(x, top, bw, ht + 0.2), layer.2)
                if rand(0...1) < 0.25 { fill(rect(x + bw / 2 - 0.001, top - 0.03, 0.002, 0.03), layer.2) }
                if layer.3 {
                    let cols = max(1, Int(bw / 0.011)), rows = max(1, Int(ht / 0.02))
                    for cI in 0..<cols {
                        for rI in 0..<rows where rand(0...1) < 0.4 {
                            fill(rect(x + 0.006 + CGFloat(cI) * 0.011, top + 0.008 + CGFloat(rI) * 0.02, 0.005, 0.01),
                                 (1, 0.86, 0.46), 0.85)
                        }
                    }
                }
                x += bw + rand(0.0...0.004)
            }
        }
    }

    // MARK: 10. Monsoon Forest

    func monsoonForest() {
        sky([(0.66, 0.74, 0.72), (0.84, 0.89, 0.85)], to: 0.6)
        let tones: [RGB] = [(0.60, 0.72, 0.66), (0.44, 0.62, 0.52), (0.32, 0.52, 0.42), (0.20, 0.38, 0.30), (0.11, 0.25, 0.20)]
        let bases: [CGFloat] = [0.44, 0.54, 0.64, 0.75, 0.88]
        for (i, base) in bases.enumerated() {
            let n = 26 + i * 2
            let lift: CGFloat = i >= 3 ? 0.3 : 0.05
            for j in 0...n {
                let u = CGFloat(j) / CGFloat(n)
                let edge = pow(abs(u - 0.5) * 2, 2)
                let y = base - lift * edge + rand(-0.015...0.015)
                let rr = rand(0.045...0.085) * (0.8 + 0.1 * CGFloat(i))
                fill(oval(u, y, rr, rr * w / h * 0.8 * 0.9), tones[i])
            }
            fill(rect(-0.01, base + 0.02, 1.02, 1.1 - base), tones[i])
            if i < 4 {
                g.fill(Path(CGRect(x: 0, y: (base - 0.05) * h, width: w, height: 0.2 * h)),
                       with: .linearGradient(Gradient(colors: [pen((0.92, 0.96, 0.94), 0), pen((0.92, 0.96, 0.94), 0.42), pen((0.92, 0.96, 0.94), 0)]),
                                             startPoint: CGPoint(x: 0, y: (base - 0.05) * h),
                                             endPoint: CGPoint(x: 0, y: (base + 0.15) * h)))
            }
        }
        for x in [0.05, 0.12, 0.9, 0.96] as [CGFloat] {
            stroke(Path { p in
                p.move(to: pt(x, 0.35)); p.addLine(to: pt(x + rand(-0.02...0.02), 1.02))
            }, (0.08, 0.18, 0.15), 0.012 * w, 0.8)
        }
        for _ in 0..<260 {
            let x = rand(0...1.05) * w, y = rand(-0.05...1) * h, l = rand(0.03...0.06) * h
            var p = Path()
            p.move(to: CGPoint(x: x, y: y))
            p.addLine(to: CGPoint(x: x - l * 0.16, y: y + l))
            stroke(p, (0.92, 0.96, 0.98), 0.9, 0.3)
        }
    }
}
