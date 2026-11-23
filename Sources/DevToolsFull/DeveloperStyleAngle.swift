import AppKit
import SwiftUI

/// A CSS angle as Chrome's CSSAngle editor reads and writes one: a number
/// and its unit (deg, grad, rad or turn), kept when the angle changes.
struct DeveloperAngle: Equatable {
    enum Unit: String, CaseIterable {
        case deg, grad, rad, turn
    }

    var value: Double
    var unit: Unit

    init(value: Double, unit: Unit) {
        self.value = value
        self.unit = unit
    }

    /// `45deg`, `-1.5rad`, `.25turn`, `100GRAD`; nil for anything else.
    init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard let unit = Unit.allCases.first(where: { trimmed.hasSuffix($0.rawValue) }) else { return nil }
        let number = String(trimmed.dropLast(unit.rawValue.count))
        // "grad" ends in "rad": the longer name wins, as it is listed first.
        guard !number.isEmpty, number.last != "g", let value = Double(number), value.isFinite else { return nil }
        self.value = value
        self.unit = unit
    }

    var degrees: Double { Self.degrees(value, from: unit) }

    static func degrees(_ value: Double, from unit: Unit) -> Double {
        switch unit {
        case .deg: value
        case .grad: value * 0.9
        case .rad: value * 180 / .pi
        case .turn: value * 360
        }
    }

    static func value(fromDegrees degrees: Double, in unit: Unit) -> Double {
        switch unit {
        case .deg: degrees
        case .grad: degrees / 0.9
        case .rad: degrees * .pi / 180
        case .turn: degrees / 360
        }
    }

    /// The same angle in another unit.
    func converted(to unit: Unit) -> DeveloperAngle {
        DeveloperAngle(value: Self.value(fromDegrees: degrees, in: unit), unit: unit)
    }

    /// Chrome's roundAngleByUnit: whole degrees and gradians, radians to
    /// four places, turns to two.
    func roundedByUnit() -> DeveloperAngle {
        let places: Double
        switch unit {
        case .deg, .grad: places = 1
        case .rad: places = 10_000
        case .turn: places = 100
        }
        return DeveloperAngle(value: (value * places).rounded() / places, unit: unit)
    }

    var css: String { DeveloperStyleEditing.format(value) + unit.rawValue }

    /// The dial dragged to `degrees` (0 at twelve o'clock, clockwise), in
    /// this angle's unit, rounded as Chrome rounds it. With Shift the dial
    /// snaps to 15° steps.
    func dialed(to degrees: Double, snapping: Bool) -> DeveloperAngle {
        let shown = snapping ? Self.snap(degrees) : degrees
        return DeveloperAngle(value: Self.value(fromDegrees: shown, in: unit), unit: unit).roundedByUnit()
    }

    /// The nearest multiple of `step` degrees, within 0..<360.
    static func snap(_ degrees: Double, step: Double = 15) -> Double {
        normalized((degrees / step).rounded() * step)
    }

    static func normalized(_ degrees: Double) -> Double {
        let turned = degrees.truncatingRemainder(dividingBy: 360)
        return turned < 0 ? turned + 360 : turned
    }

    /// Chrome's getNewAngleFromEvent: ↑ or ↓ turns the angle by 1°, 10°
    /// with Shift, written back in its own unit.
    func stepped(up: Bool, shift: Bool) -> DeveloperAngle {
        let delta = (up ? 1.0 : -1.0) * (shift ? 10 : 1)
        if unit == .deg { return DeveloperAngle(value: value + delta, unit: .deg) }
        let places: Double = unit == .grad ? 100 : 10_000
        let moved = Self.value(fromDegrees: degrees + delta, in: unit)
        return DeveloperAngle(value: (moved * places).rounded() / places, unit: unit)
    }

    /// Where a point on the dial points: degrees clockwise from twelve
    /// o'clock, 0..<360, in a y-down view.
    static func degrees(at point: CGPoint, center: CGPoint) -> Double {
        let dx = Double(point.x - center.x), dy = Double(point.y - center.y)
        guard dx != 0 || dy != 0 else { return 0 }
        return normalized(atan2(dx, -dy) * 180 / .pi)
    }

    /// The angles in a declaration's value, where each one is.
    /// Made once: the Styles pane looks for angles each time it draws a value.
    private static let expression = try? NSRegularExpression(
        pattern: #"(?<![\w.#-])-?(?:\d+(?:\.\d+)?|\.\d+)(?:deg|grad|rad|turn)\b"#, options: [.caseInsensitive])

    static func matches(in value: String) -> [(range: Range<String.Index>, angle: DeveloperAngle)] {
        guard let expression = Self.expression else { return [] }
        let range = NSRange(value.startIndex..., in: value)
        return expression.matches(in: value, range: range).compactMap { match in
            guard let found = Range(match.range, in: value), let angle = DeveloperAngle(String(value[found])) else { return nil }
            return (range: found, angle: angle)
        }
    }

    /// The value with its `index`th angle replaced.
    static func replacing(_ index: Int, in value: String, with angle: DeveloperAngle) -> String {
        let found = matches(in: value)
        guard found.indices.contains(index) else { return value }
        return value.replacingCharacters(in: found[index].range, with: angle.css)
    }
}

/// The clock icon Chrome draws before an angle in Styles; clicked, the
/// dial to set it.
struct DeveloperAngleSwatch: View {
    let value: String
    let index: Int
    let onChange: ((String) -> Void)?
    @State private var shown = false

    var body: some View {
        let found = DeveloperAngle.matches(in: value)
        if found.indices.contains(index) {
            let angle = found[index].angle
            Button { if onChange != nil { shown = true } } label: {
                DeveloperAngleClock(degrees: angle.degrees).frame(width: 10, height: 10)
            }
            .buttonStyle(.plain)
            .help(onChange == nil ? angle.css : "Open angle editor")
            .accessibilityLabel("Open angle editor")
            .popover(isPresented: $shown, arrowEdge: .bottom) {
                DeveloperAngleEditor(angle: angle) { new in
                    onChange?(DeveloperAngle.replacing(index, in: value, with: new))
                }
            }
        }
    }
}

/// A clock face with its hand at `degrees`.
struct DeveloperAngleClock: View {
    let degrees: Double
    var lineWidth: CGFloat = 1

    var body: some View {
        GeometryReader { space in
            let size = min(space.size.width, space.size.height)
            let center = CGPoint(x: space.size.width / 2, y: space.size.height / 2)
            let radius = size / 2 - lineWidth / 2
            let radians = degrees * .pi / 180
            ZStack {
                Circle().strokeBorder(DeveloperToolsStyle.tint, lineWidth: lineWidth)
                Path { path in
                    path.move(to: center)
                    path.addLine(to: CGPoint(x: center.x + radius * CGFloat(sin(radians)),
                                             y: center.y - radius * CGFloat(cos(radians))))
                }
                .stroke(DeveloperToolsStyle.tint, lineWidth: lineWidth)
            }
        }
    }
}

/// Chrome's CSSAngleEditor: a dial dragged to the angle (Shift snaps to
/// 15°), ↑ and ↓ turning it by 1° (10° with Shift), its unit kept.
struct DeveloperAngleEditor: View {
    @State var angle: DeveloperAngle
    let onChange: (DeveloperAngle) -> Void
    @FocusState private var focused: Bool
    private let size: CGFloat = 110

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle().fill(Color.secondary.opacity(0.08))
                ForEach(0..<24, id: \.self) { tick in
                    self.tick(tick)
                }
                DeveloperAngleClock(degrees: angle.degrees, lineWidth: 2).padding(6)
                Circle().fill(DeveloperToolsStyle.tint).frame(width: 5, height: 5)
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                let degrees = DeveloperAngle.degrees(at: drag.location, center: CGPoint(x: size / 2, y: size / 2))
                set(angle.dialed(to: degrees, snapping: NSEvent.modifierFlags.contains(.shift)))
            })
            .accessibilityElement()
            .accessibilityLabel("Angle")
            .accessibilityValue(angle.css)
            .accessibilityAdjustableAction { direction in
                set(angle.stepped(up: direction == .increment, shift: false))
            }
            Text(angle.css).font(DeveloperToolsStyle.code).monospacedDigit()
        }
        .padding(10)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onAppear { focused = true }
        .onKeyPress(keys: [.upArrow, .downArrow, .rightArrow, .leftArrow], phases: [.down, .repeat]) { press in
            let up = press.key == .upArrow || press.key == .rightArrow
            set(angle.stepped(up: up, shift: press.modifiers.contains(.shift)))
            return .handled
        }
    }

    /// The dial's marks every 15°, longer every 90°.
    private func tick(_ tick: Int) -> some View {
        let major: Bool = tick % 6 == 0
        let length: CGFloat = major ? 6 : 3
        return Rectangle().fill(Color.secondary.opacity(major ? 0.6 : 0.3))
            .frame(width: 1, height: length)
            .offset(y: -size / 2 + length / 2)
            .rotationEffect(.degrees(Double(tick) * 15))
    }

    private func set(_ new: DeveloperAngle) {
        guard new != angle else { return }
        angle = new
        onChange(new)
    }
}
