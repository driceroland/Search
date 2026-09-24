#if DEBUG
import AppKit
import ScreenCaptureKit

/// Native appearance checks in an isolated SEARCH_PROBE process only.
@MainActor
enum NativeProbe {
    static func run(_ request: [String: Any], browser: Browser) -> [String: Any] {
        guard Store.testing else { return ["error": "test process required"] }
        if request["action"] as? String == "save" {
            browser.flushSession()
            return ["saved": true]
        }
        let window = Links.window
        switch request["action"] as? String ?? "nodes" {
        case "accent":
            let color = NSColor(browser.prefs.chromeAccent.resolved(for: browser.active?.pageAccent))
                .usingColorSpace(.deviceRGB) ?? .black
            return ["mode": browser.prefs.chromeAccent.rawValue,
                    "rgb": [color.redComponent, color.greenComponent, color.blueComponent]]
        case "nodes":
            guard let window else { return ["error": "no window"] }
            return ["modal": NSApp.modalWindow != nil, "nodes": nodes(window).enumerated().map { index, node in
                let frame = (property(node, "accessibilityFrame") as? NSValue)?.rectValue ?? .zero
                return ["index": index, "role": text(node, "accessibilityRole"),
                        "label": text(node, "accessibilityLabel"), "title": text(node, "accessibilityTitle"),
                        "value": String(describing: property(node, "accessibilityValue") ?? ""),
                        "enabled": property(node, "isAccessibilityEnabled") as? Bool ?? false,
                        "focused": property(node, "isAccessibilityFocused") as? Bool ?? false,
                        "frame": [frame.minX, frame.minY, frame.width, frame.height]] as [String: Any]
            }]
        case "press":
            guard let window else { return ["error": "window required"] }
            let elements = nodes(window)
            let index: Int?
            if let label = request["label"] as? String {
                index = elements.firstIndex {
                    text($0, "accessibilityRole") != "AXStaticText"
                        && [text($0, "accessibilityLabel"), text($0, "accessibilityTitle")].contains(label)
                }
            } else { index = request["index"] as? Int }
            guard let index else { return ["error": "control required"] }
            guard elements.indices.contains(index) else { return ["error": "node missing"] }
            return ["pressed": property(elements[index], "accessibilityPerformPress") as? Bool ?? false]
        case "increment", "decrement":
            guard let window, let index = request["index"] as? Int else { return ["error": "index required"] }
            let elements = nodes(window)
            guard elements.indices.contains(index) else { return ["error": "node missing"] }
            let action = request["action"] as? String == "increment"
                ? "accessibilityPerformIncrement" : "accessibilityPerformDecrement"
            guard elements[index].responds(to: NSSelectorFromString(action))
            else { return ["error": "control is not adjustable"] }
            // SwiftUI performs the adjustment but may return void rather than
            // AppKit's Bool. The caller verifies the value on the next turn.
            _ = property(elements[index], action)
            return ["requested": true]
        case "hit-test":
            guard let window, let root = window.contentView?.superview,
                  let x = request["x"] as? Double, let y = request["y"] as? Double
            else { return ["error": "window and point required"] }
            let point = NSPoint(x: x, y: window.frame.height - y)
            let hit = root.hitTest(root.convert(point, from: nil))
            return ["hit": hit.map { String(describing: type(of: $0)) } ?? "none",
                    "frame": hit.map { NSStringFromRect($0.frame) } ?? "",
                    "key": window.isKeyWindow, "visible": window.isVisible,
                    "active": NSApp.isActive,
                    "backdrops": views(root).filter { $0.identifier?.rawValue == "page-chrome-backdrop" }.map {
                        ["alpha": $0.alphaValue, "usesCoreImage": $0.layerUsesCoreImageFilters,
                         "layer": $0.layer.map { String(describing: type(of: $0)) } ?? "none",
                         "parent": $0.superview.map { String(describing: type(of: $0)) } ?? "none",
                         "layerFilters": ($0.layer?.backgroundFilters as? [CIFilter] ?? []).map { $0.name },
                         "filters": $0.backgroundFilters.map {
                            ["name": $0.name, "radius": $0.inputKeys.contains("inputRadius") ? ($0.value(forKey: "inputRadius") ?? 0) : 0] as [String: Any]
                        }] as [String: Any]
                    },
                    "effects": views(root).compactMap { $0 as? NSVisualEffectView }.map {
                        ["frame": NSStringFromRect($0.frame), "alpha": $0.alphaValue,
                         "identifier": $0.identifier?.rawValue ?? "", "hidden": $0.isHidden,
                         "mode": $0.blendingMode.rawValue, "material": $0.material.rawValue] as [String: Any]
                    }]
        case "composited-shot":
            guard #available(macOS 14.4, *), let window, let path = request["path"] as? String
            else { return ["error": "window, path and macOS 14.4 required"] }
            Task { @MainActor in
                var result: [String: Any]
                do {
                    // Only this process's windows; never request screen access.
                    let content = try await SCShareableContent.currentProcess
                    guard let source = content.windows.first(where: {
                        $0.windowID == CGWindowID(window.windowNumber)
                            && $0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier
                    }) else { throw NSError(domain: "SearchProbe", code: 1, userInfo: [NSLocalizedDescriptionKey: "Owned window unavailable to compositor capture"]) }
                    let config = SCStreamConfiguration()
                    config.width = Int(window.frame.width * window.backingScaleFactor)
                    config.height = Int(window.frame.height * window.backingScaleFactor)
                    config.showsCursor = false
                    config.ignoreShadowsSingleWindow = true
                    let image = try await SCScreenshotManager.captureImage(
                        contentFilter: SCContentFilter(desktopIndependentWindow: source), configuration: config)
                    guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
                    else { throw NSError(domain: "SearchProbe", code: 2) }
                    try data.write(to: URL(fileURLWithPath: path), options: .atomic)
                    result = ["path": path, "width": image.width, "height": image.height]
                    if let rects = request["contrastRects"] as? [[Double]] {
                        let bitmap = NSBitmapImageRep(cgImage: image)
                        let scale = Double(image.width) / window.frame.width
                        var means: [[Double]] = []
                        result["contrast"] = rects.map { rect -> Double in
                            guard rect.count == 4 else { return -1 }
                            let x0 = max(0, Int(rect[0] * scale)), y0 = max(0, Int(rect[1] * scale))
                            let x1 = min(image.width, Int((rect[0] + rect[2]) * scale))
                            let y1 = min(image.height, Int((rect[1] + rect[3]) * scale))
                            guard x1 > x0, y1 > y0 else { return -1 }
                            var sum = [Double](repeating: 0, count: 3), squares = sum
                            for y in y0..<y1 { for x in x0..<x1 {
                                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                                for (i, c) in [color.redComponent, color.greenComponent, color.blueComponent].enumerated() {
                                    sum[i] += c; squares[i] += c * c
                                }
                            } }
                            let count = Double((x1 - x0) * (y1 - y0))
                            means.append(sum.map { $0 / count * 255 })
                            return (0..<3).reduce(0.0) { total, i in
                                total + sqrt(max(0, squares[i] / count - pow(sum[i] / count, 2))) * 255 / 3
                            }
                        }
                        result["colorMeans"] = means
                    }
                } catch { result = ["error": error.localizedDescription] }
                if let data = try? JSONSerialization.data(withJSONObject: result) {
                    try? data.write(to: URL(fileURLWithPath: path + ".json"), options: .atomic)
                }
            }
            return ["scheduled": true]
        case "shot":
            guard let view = window?.contentView, let path = request["path"] as? String,
                  let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)
            else { return ["error": "window or path missing"] }
            view.layoutSubtreeIfNeeded()
            view.cacheDisplay(in: view.bounds, to: bitmap)
            guard let data = bitmap.representation(using: .png, properties: [:]) else { return ["error": "PNG failed"] }
            do { try data.write(to: URL(fileURLWithPath: path), options: .atomic) }
            catch { return ["error": error.localizedDescription] }
            return ["path": path, "width": bitmap.pixelsWide, "height": bitmap.pixelsHigh]
        default:
            return ["error": "unknown native action"]
        }
    }

    private static func views(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(views)
    }

    private static func property(_ node: NSObject, _ getter: String) -> Any? {
        guard node.responds(to: NSSelectorFromString(getter)) else { return nil }
        return node.value(forKey: getter)
    }

    private static func text(_ node: NSObject, _ getter: String) -> String {
        // SwiftUI can return attributed labels despite AppKit's NSString type.
        guard let value = property(node, getter) else { return "" }
        if let attributed = value as? NSAttributedString { return attributed.string }
        return value as? String ?? ""
    }

    private static func nodes(_ root: NSObject) -> [NSObject] {
        var seen = Set<ObjectIdentifier>()
        func walk(_ node: NSObject, depth: Int) -> [NSObject] {
            guard depth < 30, seen.insert(ObjectIdentifier(node as AnyObject)).inserted else { return [] }
            // SwiftUI's accessibility objects expose these Objective-C getters
            // without declaring NSAccessibilityProtocol conformance.
            return [node] + (property(node, "accessibilityChildren") as? [NSObject] ?? [])
                .flatMap { walk($0, depth: depth + 1) }
        }
        return walk(root, depth: 0)
    }
}

#endif
