// The app's icon, drawn rather than exported: the mark is the column, read
// from its own path data rather than loaded as an image,
// so it stays a crisp vector at every size instead of a raster scaled up.
// The icon puts it on a plate — a Dock icon has to be an opaque square
// whether the logo itself wants a background or not.

import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "AppIcon.iconset")

/// A dev build (build.sh) puts the mark on a yellow plate rather than a white
/// one, as Chrome Canary does, so the build from a worktree and the installed
/// app are told apart at a glance: in the Dock, in ⌘Tab, at 16 points.
let dev = ProcessInfo.processInfo.environment["SEARCH_DEV"] == "1"
let plateColor = dev ? NSColor(srgbRed: 1.0, green: 0.8, blue: 0.2, alpha: 1) : NSColor.white
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

/// The column (22 November 2026): a narrow bar and a block beside it — the
/// window itself, tabs down the left and the page next to them — on its own
/// 320 × 276 canvas. The same path is in Design.swift's `Logomark`.
let canvas = (width: 320.0, height: 276.0)

/// How much of the plate's width the mark takes. The column is nearly
/// square, so it sits at a little over half the plate, where the old wide
/// pill took three quarters.
let markFraction: CGFloat = 0.56
let markData = "M36 0C55.882 0 72 16.118 72 36L72 240C72 259.882 55.882 276 36 276C16.118 276 0 259.882 0 240L0 36C0 16.118 16.118 0 36 0ZM260 0C293.137 0 320 26.863 320 60L320 216C320 249.137 293.137 276 260 276L164 276C130.863 276 104 249.137 104 216L104 60C104 26.863 130.863 0 164 0Z"

/// A tiny reader for the one path the mark is: absolute M, L, H, V, C, Z —
/// what Figma writes for a flattened shape, and nothing else.
func svgCommands(_ d: String) -> [(Character, [CGFloat])] {
    var out: [(Character, [CGFloat])] = []
    var current: Character?
    var numbers: [CGFloat] = []
    var token = ""
    func flushNumber() {
        if !token.isEmpty, let v = Double(token) { numbers.append(CGFloat(v)) }
        token = ""
    }
    for ch in d {
        if "MLHVCZmlhvcz".contains(ch) {
            flushNumber()
            if let current { out.append((current, numbers)) }
            current = ch
            numbers = []
        } else if ch == " " || ch == "," {
            flushNumber()
        } else if ch == "-" && !token.isEmpty && !token.hasSuffix("e") {
            flushNumber()
            token = "-"
        } else {
            token.append(ch)
        }
    }
    flushNumber()
    if let current { out.append((current, numbers)) }
    return out
}

/// The mark, fit to `fraction` of `plate`'s width and centred on it. SVG's y
/// grows downward and AppKit's upward, so every y is flipped on the way in;
/// the path is filled even-odd, as a mark with a hole would need.
func markPath(in plate: NSRect, fraction: CGFloat) -> NSBezierPath {
    let scale = plate.width * fraction / canvas.width
    let ox = plate.midX - canvas.width * scale / 2
    let oy = plate.midY - canvas.height * scale / 2
    func pt(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
        NSPoint(x: ox + x * scale, y: oy + (canvas.height - y) * scale)
    }
    let path = NSBezierPath()
    path.windingRule = .evenOdd
    var last = NSPoint.zero
    var start = NSPoint.zero
    for (c, n) in svgCommands(markData) {
        switch c {
        case "M": last = NSPoint(x: n[0], y: n[1]); start = last; path.move(to: pt(n[0], n[1]))
        case "L": last = NSPoint(x: n[0], y: n[1]); path.line(to: pt(n[0], n[1]))
        case "H": last.x = n[0]; path.line(to: pt(last.x, last.y))
        case "V": last.y = n[0]; path.line(to: pt(last.x, last.y))
        case "C":
            var k = 0
            while k + 5 < n.count {
                path.curve(to: pt(n[k + 4], n[k + 5]), controlPoint1: pt(n[k], n[k + 1]), controlPoint2: pt(n[k + 2], n[k + 3]))
                last = NSPoint(x: n[k + 4], y: n[k + 5])
                k += 6
            }
        case "Z": path.close(); last = start
        default: break
        }
    }
    return path
}

func draw(_ size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    defer { image.unlockFocus() }

    // Apple's grid: the shape takes 824 of 1024, and its corners are 22.37%.
    let s = size / 1024
    let plate = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let radius = 824 * 0.2237 * s
    let shape = NSBezierPath(roundedRect: plate, xRadius: radius, yRadius: radius)

    // A soft shadow under the plate, the way every icon on the Dock has one.
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.18)
    shadow.shadowBlurRadius = 24 * s
    shadow.shadowOffset = NSSize(width: 0, height: -10 * s)
    shadow.set()
    plateColor.setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    // The mark, black on the plate, centred.
    NSColor(red: 0.09, green: 0.09, blue: 0.09, alpha: 1).setFill()
    markPath(in: plate, fraction: markFraction).fill()
    return image
}

func write(_ image: NSImage, to url: URL, pixels: Int) {
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff)
    else { return }
    // The bitmap is asked for at the pixel size, whatever the screen thinks.
    let sized = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    sized.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: sized)
    NSGraphicsContext.current?.imageInterpolation = .high
    rep.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    guard let png = sized.representation(using: .png, properties: [:]) else { return }
    try? png.write(to: url)
}

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let image = draw(CGFloat(pixels))
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        write(image, to: out.appendingPathComponent(name), pixels: pixels)
    }
}
print("drew: \(out.path)")

// The same icon as an Icon Composer document, when a second path is given.
// macOS 26 lets the Dock show icons Dark, Clear or Tinted, and it can only
// do that well with an icon that says what each style should be: from the
// flat image above it made a darkened plate with the black mark still on
// it, black on black (#337). Here the plate and the mark are separate, so
// Dark turns them round — a white mark on the ink colour — and Tinted
// gets a white mark whose brightness the system tints. The light look is left as it is: the same white, the same
// ink, the mark at the same size, and no glass, gloss or shadow of its own.
// build.sh compiles it with actool; the images above stay the .icns.
if CommandLine.arguments.count > 2 {
    let doc = URL(fileURLWithPath: CommandLine.arguments[2])
    let assets = doc.appendingPathComponent("Assets")
    try? FileManager.default.removeItem(at: doc)
    try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)

    // An Icon Composer canvas is the plate, 1024 points across; the mark
    // takes the same share of it as it does of the plate drawn above.
    let width = 1024 * markFraction
    let height = width * canvas.height / canvas.width
    let svg = """
    <svg xmlns="http://www.w3.org/2000/svg" width="\(width)" height="\(height)" viewBox="0 0 \(Int(canvas.width)) \(Int(canvas.height))">\
    <path fill-rule="evenodd" fill="#171717" d="\(markData)"/></svg>
    """
    try svg.write(to: assets.appendingPathComponent("mark.svg"), atomically: true, encoding: .utf8)

    let white = #"{ "solid" : "srgb:1.00000,1.00000,1.00000,1.00000" }"#
    let yellow = #"{ "solid" : "srgb:1.00000,0.80000,0.20000,1.00000" }"#
    let ink = #"{ "solid" : "srgb:0.09000,0.09000,0.09000,1.00000" }"#
    // A dev build keeps its yellow in Dark too: the plate yellow in light,
    // the mark yellow on ink in dark.
    let plate = dev ? yellow : white
    let json = """
    {
      "fill" : \(plate),
      "fill-specializations" : [
        { "value" : \(plate) },
        { "appearance" : "dark", "value" : \(ink) }
      ],
      "groups" : [
        {
          "layers" : [
            {
              "name" : "mark",
              "image-name" : "mark.svg",
              "glass" : false,
              "fill-specializations" : [
                { "value" : \(ink) },
                { "appearance" : "dark", "value" : \(plate) },
                { "appearance" : "tinted", "value" : \(white) }
              ]
            }
          ],
          "shadow" : { "kind" : "none", "opacity" : 0.5 },
          "specular" : false,
          "translucency" : { "enabled" : false, "value" : 0.5 }
        }
      ],
      "supported-platforms" : { "squares" : [ "macOS" ] }
    }
    """
    try json.write(to: doc.appendingPathComponent("icon.json"), atomically: true, encoding: .utf8)
    print("wrote: \(doc.path)")
}
