import Foundation

/// One entry in the device toolbar's list, as Chrome DevTools describes it
/// (`models/emulation/EmulatedDevices.ts`): portrait CSS size, device pixel
/// ratio, user agent and capabilities.
struct DeveloperEmulatedDevice: Identifiable, Hashable, Codable {
    enum DeviceType: String, Codable, CaseIterable, Identifiable {
        case mobile = "Mobile"
        case desktop = "Desktop"

        var id: Self { self }
    }

    var title: String
    var width: Int
    var height: Int
    var deviceScaleFactor: Double
    var type: DeviceType
    var touch: Bool
    var userAgent: String
    var custom = false
    /// Chrome's `show-by-default`: listed in the toolbar until the user edits the list.
    var shownByDefault = true

    var id: String { (custom ? "custom:" : "") + title }

    init(_ title: String, _ width: Int, _ height: Int, dpr: Double, _ type: DeviceType, touch: Bool, shown: Bool,
         ua: String) {
        self.title = title
        self.width = width
        self.height = height
        deviceScaleFactor = dpr
        self.type = type
        self.touch = touch
        userAgent = ua
        shownByDefault = shown
    }

    init(custom title: String, width: Int, height: Int, deviceScaleFactor: Double, type: DeviceType, userAgent: String) {
        self.init(title, width, height, dpr: deviceScaleFactor, type, touch: type == .mobile, shown: true, ua: userAgent)
        custom = true
    }
}

/// The device list and the user's edits to it.
enum DeveloperDevices {
    /// Chrome substitutes its own version into Chromium user agents.
    static let chrome = "143.0.0.0"
    /// Chrome's `defaultMobileUserAgent` for Responsive with device type Mobile.
    static let responsiveMobileUserAgent = android("10; K")
    /// Chrome's `defaultMobileScaleFactor`.
    static let responsiveMobileScaleFactor = 2.0

    private static let shownKey = "developerTools.devices.shown"
    private static let customKey = "developerTools.devices.custom"

    /// Every device, built in first, in Chrome's order.
    static var all: [DeveloperEmulatedDevice] { builtIn + custom }

    /// The devices listed in the toolbar menu.
    static var shown: [DeveloperEmulatedDevice] {
        let chosen = Store.settings.stringArray(forKey: shownKey).map(Set.init)
        return all.filter { chosen?.contains($0.id) ?? ($0.custom || $0.shownByDefault) }
    }

    static func setShown(ids: Set<String>) {
        Store.settings.set(all.map(\.id).filter(ids.contains), forKey: shownKey)
    }

    static var custom: [DeveloperEmulatedDevice] {
        guard let data = Store.settings.data(forKey: customKey),
              let devices = try? JSONDecoder().decode([DeveloperEmulatedDevice].self, from: data) else { return [] }
        return devices.filter(\.custom)
    }

    static func saveCustom(_ devices: [DeveloperEmulatedDevice]) {
        let unique = devices.reduce(into: [DeveloperEmulatedDevice]()) { list, device in
            if !list.contains(where: { $0.id == device.id }) { list.append(device) }
        }
        if let data = try? JSONEncoder().encode(unique) { Store.settings.set(data, forKey: customKey) }
    }

    static func device(id: String) -> DeveloperEmulatedDevice? { all.first { $0.id == id } }

    private static let iPhone = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Mobile/15E148 Safari/604.1"
    private static let windows = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/\(chrome) Safari/537.36"
    /// Chrome's mobile user agent on Android `model` ("14; Pixel 9").
    private static func android(_ model: String) -> String {
        "Mozilla/5.0 (Linux; Android \(model)) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/\(chrome) Mobile Safari/537.36"
    }

    static let builtIn: [DeveloperEmulatedDevice] = [
        .init("JioPhone 2", 240, 320, dpr: 1, .mobile, touch: true, shown: false,
              ua: "Mozilla/5.0 (Mobile; LYF/F300B/LYF-F300B-001-01-15-130718-i;Android; rv:48.0) Gecko/48.0 Firefox/48.0 KAIOS/2.5"),
        .init("iPhone SE", 375, 667, dpr: 2, .mobile, touch: true, shown: true, ua: iPhone),
        .init("iPhone XR", 414, 896, dpr: 2, .mobile, touch: true, shown: false, ua: iPhone),
        .init("iPhone 12 Pro", 390, 844, dpr: 3, .mobile, touch: true, shown: false, ua: iPhone),
        .init("iPhone 14", 390, 844, dpr: 3, .mobile, touch: true, shown: false, ua: iPhone),
        .init("iPhone 14 Plus", 428, 926, dpr: 3, .mobile, touch: true, shown: false, ua: iPhone),
        .init("iPhone 14 Pro", 393, 852, dpr: 3, .mobile, touch: true, shown: false, ua: iPhone),
        .init("iPhone 14 Pro Max", 430, 932, dpr: 3, .mobile, touch: true, shown: false, ua: iPhone),
        .init("iPhone 15", 393, 852, dpr: 3, .mobile, touch: true, shown: false, ua: iPhone),
        .init("iPhone 15 Plus", 430, 932, dpr: 3, .mobile, touch: true, shown: false, ua: iPhone),
        .init("iPhone 15 Pro", 393, 852, dpr: 3, .mobile, touch: true, shown: false, ua: iPhone),
        .init("iPhone 15 Pro Max", 430, 932, dpr: 3, .mobile, touch: true, shown: false, ua: iPhone),
        .init("iPhone 16e", 390, 844, dpr: 3, .mobile, touch: true, shown: false, ua: iPhone),
        .init("iPhone 16", 393, 852, dpr: 3, .mobile, touch: true, shown: true, ua: iPhone),
        .init("iPhone 16 Plus", 430, 932, dpr: 3, .mobile, touch: true, shown: false, ua: iPhone),
        .init("iPhone 16 Pro", 402, 874, dpr: 3, .mobile, touch: true, shown: false, ua: iPhone),
        .init("iPhone 16 Pro Max", 440, 956, dpr: 3, .mobile, touch: true, shown: true, ua: iPhone),
        .init("Pixel 7", 412, 915, dpr: 2.625, .mobile, touch: true, shown: false, ua: android("13; Pixel 7")),
        .init("Pixel 8", 412, 915, dpr: 2.625, .mobile, touch: true, shown: false, ua: android("14; Pixel 8")),
        .init("Pixel 8 Pro", 448, 997, dpr: 3, .mobile, touch: true, shown: false, ua: android("14; Pixel 8 Pro")),
        .init("Pixel 8a", 412, 915, dpr: 2.625, .mobile, touch: true, shown: false, ua: android("14; Pixel 8a")),
        .init("Pixel 9", 412, 924, dpr: 2.625, .mobile, touch: true, shown: true, ua: android("14; Pixel 9")),
        .init("Pixel 9 Pro", 427, 952, dpr: 3, .mobile, touch: true, shown: true, ua: android("14; Pixel 9 Pro")),
        .init("Pixel 9 Pro XL", 448, 997, dpr: 3, .mobile, touch: true, shown: false, ua: android("14; Pixel 9 Pro XL")),
        .init("Pixel 10", 412, 924, dpr: 2.625, .mobile, touch: true, shown: true, ua: android("16; Pixel 10")),
        .init("Samsung Galaxy S8+", 360, 740, dpr: 4, .mobile, touch: true, shown: false,
              ua: android("8.0.0; SM-G955U Build/R16NW")),
        .init("Samsung Galaxy A55", 360, 800, dpr: 2.25, .mobile, touch: true, shown: true, ua: android("14; SM-A556B")),
        .init("Samsung Galaxy S20 Ultra", 412, 915, dpr: 3.5, .mobile, touch: true, shown: false, ua: android("13; SM-G981B")),
        .init("iPad Mini", 768, 1024, dpr: 2, .mobile, touch: true, shown: true,
              ua: "Mozilla/5.0 (iPad; CPU OS 18_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Mobile/15E148 Safari/604.1"),
        .init("iPad Pro 13", 1032, 1376, dpr: 2, .mobile, touch: true, shown: true,
              ua: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Safari/605.1.15"),
        .init("Surface Pro 7", 912, 1368, dpr: 2, .mobile, touch: true, shown: false, ua: windows),
        .init("Surface Pro 10", 960, 1440, dpr: 2, .mobile, touch: true, shown: true, ua: windows),
        .init("Surface Duo", 540, 720, dpr: 2.5, .mobile, touch: true, shown: false, ua: android("11.0; Surface Duo")),
        .init("Pixel 9 Pro Fold", 412, 922, dpr: 2.625, .mobile, touch: true, shown: true, ua: android("14; Pixel 9 Pro Fold")),
        .init("Galaxy Z Fold 6", 412, 968, dpr: 2.625, .mobile, touch: true, shown: true, ua: android("14; SM-F956U")),
        .init("Galaxy Z Fold 5", 344, 882, dpr: 2.625, .mobile, touch: true, shown: false, ua: android("10; K")),
        .init("Asus Zenbook Fold", 853, 1280, dpr: 1.5, .desktop, touch: true, shown: false, ua: windows),
        .init("Samsung Galaxy A51/71", 412, 914, dpr: 2.625, .mobile, touch: true, shown: false,
              ua: android("8.0.0; SM-G955U Build/R16NW")),
        .init("Nest Hub Max", 1280, 800, dpr: 2, .mobile, touch: true, shown: true,
              ua: "Mozilla/5.0 (X11; Linux aarch64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/\(chrome) Safari/537.36 CrKey/1.54.250320"),
        .init("Facebook on Android", 412, 892, dpr: 3.5, .mobile, touch: true, shown: false,
              ua: "Mozilla/5.0 (Linux; Android 12; Pixel 6 Build/SQ3A.220705.004; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/\(chrome) Mobile Safari/537.36 [FB_IAB/FB4A;FBAV/407.0.0.0.65;]"),
        .init("Galaxy Tab S4", 712, 1138, dpr: 2.25, .mobile, touch: true, shown: false,
              ua: "Mozilla/5.0 (Linux; Android 8.1.0; SM-T837A) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/\(chrome) Safari/537.36"),
        .init("Moto G4", 360, 640, dpr: 3, .mobile, touch: true, shown: false, ua: android("6.0.1; Moto G (4)")),
        .init("Moto G Power", 412, 823, dpr: 1.75, .mobile, touch: true, shown: false,
              ua: android("11; moto g power (2022)")),
    ]
}
