import SwiftUI

/// The devtools' slider: it snaps to `step`, but draws tick marks only
/// when there are few of them (`maximumTicks` or fewer stops). Many ticks
/// crowd into a smudged line under the track, so then it snaps without
/// showing any.
struct DeveloperSlider: View {
    static let maximumTicks = 10

    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double? = nil

    init(value: Binding<Double>, in range: ClosedRange<Double>, step: Double? = nil) {
        _value = value
        self.range = range
        self.step = step
    }

    /// Whether a slider over `range` in `step`s shows its ticks.
    static func showsTicks(range: ClosedRange<Double>, step: Double?) -> Bool {
        guard let step, step > 0 else { return false }
        return ((range.upperBound - range.lowerBound) / step).rounded() <= Double(maximumTicks)
    }

    /// `value` snapped to the nearest step from the range's start, kept in range.
    static func snap(_ value: Double, range: ClosedRange<Double>, step: Double?) -> Double {
        guard let step, step > 0 else { return value }
        let snapped = range.lowerBound + ((value - range.lowerBound) / step).rounded() * step
        return min(max(snapped, range.lowerBound), range.upperBound)
    }

    var body: some View {
        if let step, Self.showsTicks(range: range, step: step) {
            Slider(value: $value, in: range, step: step)
        } else {
            Slider(value: Binding(get: { value }, set: { value = Self.snap($0, range: range, step: step) }), in: range)
        }
    }
}
