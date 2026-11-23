import AppKit
import SwiftUI

/// One entry in Chrome's location list (`ui/settings/EmulationSettings.ts`).
struct DeveloperLocation: Codable, Hashable, Identifiable {
    var title: String
    var latitude: Double
    var longitude: Double
    var timezone: String
    var locale: String
    var accuracy: Double = 150

    var id: String { title }
}

/// Chrome's Settings › Locations: the presets until the user edits the list.
enum DeveloperLocations {
    static let presets: [DeveloperLocation] = [
        .init(title: "Berlin", latitude: 52.520007, longitude: 13.404954, timezone: "Europe/Berlin", locale: "de-DE"),
        .init(title: "London", latitude: 51.507351, longitude: -0.127758, timezone: "Europe/London", locale: "en-GB"),
        .init(title: "Moscow", latitude: 55.755826, longitude: 37.6173, timezone: "Europe/Moscow", locale: "ru-RU"),
        .init(title: "Mountain View", latitude: 37.386052, longitude: -122.083851,
              timezone: "America/Los_Angeles", locale: "en-US"),
        .init(title: "Mumbai", latitude: 19.075984, longitude: 72.877656, timezone: "Asia/Kolkata", locale: "mr-IN"),
        .init(title: "San Francisco", latitude: 37.774929, longitude: -122.419416,
              timezone: "America/Los_Angeles", locale: "en-US"),
        .init(title: "Shanghai", latitude: 31.230416, longitude: 121.473701, timezone: "Asia/Shanghai",
              locale: "zh-Hans-CN"),
        .init(title: "São Paulo", latitude: -23.55052, longitude: -46.633309, timezone: "America/Sao_Paulo",
              locale: "pt-BR"),
        .init(title: "Tokyo", latitude: 35.689487, longitude: 139.691706, timezone: "Asia/Tokyo", locale: "ja-JP"),
    ]

    private static let key = "developerTools.sensors.locations"

    static var saved: [DeveloperLocation] {
        guard let data = Store.settings.data(forKey: key),
              let list = try? JSONDecoder().decode([DeveloperLocation].self, from: data) else { return presets }
        return list
    }

    static func save(_ list: [DeveloperLocation]) {
        if let data = try? JSONEncoder().encode(list) { Store.settings.set(data, forKey: key) }
    }
}

/// Chrome's Sensors drawer (`panels/sensors/SensorsView.ts`).
struct DeveloperSensorsView: View {
    @ObservedObject var session: DeveloperToolsSession
    @State private var locations = DeveloperLocations.saved
    /// "No override", a saved location's title, "Other…" or "Location unavailable".
    @State private var location = Self.noOverride
    @State private var latitude = "0"
    @State private var longitude = "0"
    @State private var timezone = ""
    @State private var locale = ""
    @State private var accuracy = "150"
    @State private var orientation = Self.off
    @State private var alpha = "0"
    @State private var beta = "90"
    @State private var gamma = "0"
    @ObservedObject private var shell = DeveloperToolsShell.shared
    @State private var dragStart: (alpha: Double, beta: Double, gamma: Double)?

    static let noOverride = "No override"
    static let other = "Other…"
    static let unavailable = "Location unavailable"
    static let off = "Off"
    static let custom = "Custom orientation"
    static let orientationPresets: [(String, Double, Double, Double)] = [
        ("Portrait", 0, 90, 0), ("Portrait upside down", 180, -90, 0), ("Landscape left", 90, 0, -90),
        ("Landscape right", 90, -180, -90), ("Display up", 0, 0, 0), ("Display down", 0, -180, 0),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                locationSection
                Divider()
                orientationSection
                Divider()
                unsupported("Touch", "Forces touch instead of click",
                            ["Device-based", "Force enabled"],
                            "WebKit can’t turn mouse input into touch events.")
                unsupported("Emulate Idle Detector state", "Forces selected idle state emulation",
                            ["No idle emulation", "User active, screen unlocked", "User active, screen locked",
                             "User idle, screen unlocked", "User idle, screen locked"],
                            "WebKit has no Idle Detection API.")
                unsupported("CPU pressure", "Forces selected pressure state emulation",
                            ["No override", "Nominal", "Fair", "Serious", "Critical"],
                            "WebKit has no Compute Pressure API.")
                if let note = activeNote {
                    Text(note).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: 640, alignment: .leading)
            .padding(DeveloperToolsStyle.gutter)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear(perform: restore)
        // Manage opens Settings › Locations, as in Chrome; what it changed
        // is read back when Settings closes.
        .onChange(of: shell.settingsShown) { _, shown in
            if !shown { locations = DeveloperLocations.saved }
        }
    }

    // MARK: Location

    private var locationSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Location").fontWeight(.semibold)
            HStack {
                Picker("Location", selection: Binding(get: { location }, set: chooseLocation)) {
                    Text(Self.noOverride).tag(Self.noOverride)
                    Section("Overrides") {
                        ForEach(locations) { Text($0.title).tag($0.title) }
                        Text(Self.other).tag(Self.other)
                    }
                    Divider()
                    Text(Self.unavailable).tag(Self.unavailable)
                }
                .labelsHidden().fixedSize()
                Button("Manage") { shell.showSettings(.locations) }
                    .help("Manage the list of locations")
            }
            if location != Self.noOverride && location != Self.unavailable {
                HStack(alignment: .bottom, spacing: 10) {
                    field("Latitude", value: $latitude)
                    field("Longitude", value: $longitude)
                }
                HStack(alignment: .bottom, spacing: 10) {
                    field("Timezone ID", value: $timezone)
                    field("Locale", value: $locale)
                    field("Accuracy", value: $accuracy)
                }
                if !locationValid {
                    Text("Enter a latitude from −90 to 90, a longitude from −180 to 180, a nonnegative accuracy, a timezone ID such as Europe/Berlin and a locale such as de-DE.")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func chooseLocation(_ value: String) {
        location = value
        if let preset = locations.first(where: { $0.title == value }) {
            latitude = String(preset.latitude)
            longitude = String(preset.longitude)
            timezone = preset.timezone
            locale = preset.locale
            accuracy = String(preset.accuracy)
        }
        apply()
    }

    private var locationValid: Bool {
        guard location != Self.noOverride && location != Self.unavailable else { return true }
        return within(latitude, -90...90) && within(longitude, -180...180) && within(accuracy, 0...100_000)
            && (timezone.isEmpty || TimeZone(identifier: timezone) != nil)
            && (locale.isEmpty || DeveloperToolsSensors.validLocale(locale))
    }

    // MARK: Orientation

    private var orientationSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Orientation").fontWeight(.semibold)
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 7) {
                    Picker("Orientation", selection: Binding(get: { orientation }, set: chooseOrientation)) {
                        Text(Self.off).tag(Self.off)
                        Text(Self.custom).tag(Self.custom)
                        Section("Presets") {
                            ForEach(Self.orientationPresets, id: \.0) { Text($0.0).tag($0.0) }
                        }
                    }
                    .labelsHidden().fixedSize()
                    if orientation != Self.off {
                        field("α (alpha)", value: $alpha)
                        field("β (beta)", value: $beta)
                        field("γ (gamma)", value: $gamma)
                        Button("Reset") {
                            (alpha, beta, gamma) = ("0", "90", "0")
                            orientation = "Portrait"
                            apply()
                        }
                        .help("Reset device orientation")
                    }
                }
                if orientation != Self.off { orientationWidget }
            }
        }
    }

    private func chooseOrientation(_ value: String) {
        orientation = value
        if let preset = Self.orientationPresets.first(where: { $0.0 == value }) {
            alpha = Self.angle(preset.1)
            beta = Self.angle(preset.2)
            gamma = Self.angle(preset.3)
        }
        apply()
    }

    /// Chrome's 3-D phone: drag to rotate around x and y, Shift-drag horizontally to rotate around z.
    private var orientationWidget: some View {
        let a = Double(alpha) ?? 0, b = Double(beta) ?? 0, g = Double(gamma) ?? 0
        return ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(DeveloperToolsStyle.raised)
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(DeveloperToolsStyle.rule, lineWidth: 1.5))
                .overlay(alignment: .top) {
                    Capsule().fill(DeveloperToolsStyle.rule).frame(width: 22, height: 4).padding(.top, 6)
                }
                .frame(width: 70, height: 130)
                .rotation3DEffect(.degrees(-a), axis: (x: 0, y: 0, z: 1))
                .rotation3DEffect(.degrees(b - 90), axis: (x: 1, y: 0, z: 0))
                .rotation3DEffect(.degrees(g), axis: (x: 0, y: 1, z: 0))
        }
        .frame(width: 170, height: 170)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 1)
            .onChanged { drag in
                let start = dragStart ?? (a, b, g)
                dragStart = start
                if NSEvent.modifierFlags.contains(.shift) {
                    alpha = Self.angle((start.alpha - drag.translation.width / 2).truncatingRemainder(dividingBy: 360)
                                       .advanced(by: 360).truncatingRemainder(dividingBy: 360))
                } else {
                    beta = Self.angle(min(180, max(-180, start.beta - drag.translation.height / 2)))
                    gamma = Self.angle(min(90, max(-90, start.gamma + drag.translation.width / 2)))
                }
                orientation = Self.custom
            }
            .onEnded { _ in
                dragStart = nil
                apply()
            })
        .help("Drag to rotate. Shift+drag horizontally to rotate around the y-axis")
        .accessibilityLabel("Device orientation set to alpha: \(alpha), beta: \(beta), gamma: \(gamma)")
    }

    private static func angle(_ value: Double) -> String {
        String(Double(Int((value * 10_000).rounded())) / 10_000)
    }

    // MARK: Shared

    private func unsupported(_ title: String, _ detail: String, _ options: [String], _ reason: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).fontWeight(.semibold)
            Picker(title, selection: .constant(options[0])) {
                ForEach(options, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden().fixedSize().disabled(true)
            Text(detail + ". " + reason).foregroundStyle(.secondary)
        }
    }

    private func field(_ name: String, value: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(name).foregroundStyle(.secondary)
            TextField(name, text: value)
                .developerToolsField()
                .font(DeveloperToolsStyle.code)
                .frame(maxWidth: 140)
                .onSubmit { fieldEdited(name) }
        }
    }

    private func fieldEdited(_ name: String) {
        if ["Latitude", "Longitude", "Timezone ID", "Locale", "Accuracy"].contains(name) {
            if let preset = locations.first(where: { $0.title == location }),
               Double(latitude) != preset.latitude || Double(longitude) != preset.longitude
                || timezone != preset.timezone || locale != preset.locale || Double(accuracy) != preset.accuracy {
                location = Self.other
            }
        } else if orientation != Self.custom {
            orientation = Self.custom
        }
        apply()
    }

    private func within(_ value: String, _ range: ClosedRange<Double>) -> Bool {
        Double(value).map(range.contains) ?? false
    }

    private var orientationValid: Bool {
        orientation == Self.off || (within(alpha, 0...360) && within(beta, -180...180) && within(gamma, -90...90))
    }

    private var activeNote: String? {
        let state = session.sensorOverride
        guard state.location != nil || state.orientation != nil || state.timezone != nil || state.locale != nil
        else { return nil }
        var note = session.sensorRepeatsOnReload
            ? "Overrides are active for this origin in the inspected tab."
            : "Overrides are active in the inspected document until reload."
        if state.timezone != nil || state.locale != nil {
            note += " The timezone and locale apply to Intl, toLocaleString() and getTimezoneOffset(); WebKit can’t change Date’s own time zone."
        }
        return note
    }

    private func apply() {
        guard locationValid, orientationValid else { return }
        var state = DeveloperToolsSensors.State()
        if location == Self.unavailable { state.location = .unavailable }
        if location != Self.noOverride, location != Self.unavailable,
           let lat = Double(latitude), let lon = Double(longitude), let acc = Double(accuracy) {
            state.location = .coordinates(latitude: lat, longitude: lon, accuracy: acc)
            state.timezone = timezone.isEmpty ? nil : timezone
            state.locale = locale.isEmpty ? nil : locale
        }
        if orientation != Self.off, let a = Double(alpha), let b = Double(beta), let g = Double(gamma) {
            state.orientation = .init(alpha: a, beta: b, gamma: g)
        }
        if state == .init() { session.resetSensors() } else { session.applySensors(state) }
    }

    private func restore() {
        let current = session.sensorOverride
        if case let .coordinates(lat, lon, acc) = current.location {
            latitude = String(lat)
            longitude = String(lon)
            accuracy = String(acc)
            timezone = current.timezone ?? ""
            locale = current.locale ?? ""
            location = locations.first {
                $0.latitude == lat && $0.longitude == lon && $0.timezone == timezone && $0.locale == locale
            }?.title ?? Self.other
        } else if case .unavailable = current.location {
            location = Self.unavailable
        }
        if let angles = current.orientation {
            alpha = Self.angle(angles.alpha)
            beta = Self.angle(angles.beta)
            gamma = Self.angle(angles.gamma)
            orientation = Self.orientationPresets.first {
                $0.1 == angles.alpha && $0.2 == angles.beta && $0.3 == angles.gamma
            }?.0 ?? Self.custom
        }
    }
}
