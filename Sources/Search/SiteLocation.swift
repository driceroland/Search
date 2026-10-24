import CoreLocation
import WebKit

// Where you are, for a page you let ask.
//
// Answering a page's question (Browser.askedForLocation) is only half of it.
// On the Mac, WebKit then asks the app for the position through a C provider
// set on the process pool's geolocation manager, and without one it asks
// nobody: the page you allowed waits out its timeout, and macOS never hears
// of Search — it was missing from System Settings › Location Services (#387).
// Safari and other WebKit browsers on the Mac bring a provider of their own,
// and so does Search, here.
//
// CoreLocation is touched only when WebKit starts updating, which it does
// only after a page has been allowed, in Search's own card or by an Always
// allow you gave that site earlier. So macOS's question comes after yours,
// never at launch. A test run never touches CoreLocation at all: the page is
// told its position can't be found.
//
// Its functions are exported but not declared anywhere Swift can see, so
// they are looked up by name; if one is missing, no provider is set and
// pages get no position, as before.

private typealias Ref = UnsafeRawPointer

/// WebKit's geolocation functions, each looked up by name.
private struct GeolocationC {
    let manager: @convention(c) (Ref) -> Ref?
    let setProvider: @convention(c) (Ref, UnsafeRawPointer) -> Void
    /// timestamp (s since 1970), latitude, longitude, accuracy (m), then
    /// altitude, its accuracy, heading and speed, each after a "provided" flag.
    let position: @convention(c) (Double, Double, Double, Double, Bool, Double, Bool, Double, Bool, Double, Bool, Double) -> Ref?
    let changed: @convention(c) (Ref, Ref) -> Void
    let failed: @convention(c) (Ref) -> Void
    let release: @convention(c) (Ref) -> Void

    static let loaded: GeolocationC? = {
        let webkit = dlopen("/System/Library/Frameworks/WebKit.framework/WebKit", RTLD_NOW)
        func f<T>(_ name: String) -> T? { dlsym(webkit, name).map { unsafeBitCast($0, to: T.self) } }
        guard let manager: @convention(c) (Ref) -> Ref? = f("WKContextGetGeolocationManager"),
              let setProvider: @convention(c) (Ref, UnsafeRawPointer) -> Void = f("WKGeolocationManagerSetProvider"),
              let position: @convention(c) (Double, Double, Double, Double, Bool, Double, Bool, Double, Bool, Double, Bool, Double) -> Ref?
                = f("WKGeolocationPositionCreate_b"),
              let changed: @convention(c) (Ref, Ref) -> Void = f("WKGeolocationManagerProviderDidChangePosition"),
              let failed: @convention(c) (Ref) -> Void = f("WKGeolocationManagerProviderDidFailToDeterminePosition"),
              let release: @convention(c) (Ref) -> Void = f("WKRelease")
        else { return nil }
        return GeolocationC(manager: manager, setProvider: setProvider, position: position, changed: changed,
                            failed: failed, release: release)
    }()
}

/// What stands in for CoreLocation: the Mac's, or a test's.
@MainActor
protocol Locating: AnyObject {
    var status: CLAuthorizationStatus { get }
    var precise: Bool { get set }
    /// macOS's own question. Only ever called while a page you allowed is
    /// waiting for its position.
    func ask()
    func start()
    func stop()
    var statusChanged: (() -> Void)? { get set }
    var found: ((CLLocation) -> Void)? { get set }
    var failed: ((Error) -> Void)? { get set }
}

/// CoreLocation itself, made the first time a page you allowed wants a position.
@MainActor
final class CoreLocator: NSObject, Locating, @preconcurrency CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    var statusChanged: (() -> Void)?
    var found: ((CLLocation) -> Void)?
    var failed: ((Error) -> Void)?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    var status: CLAuthorizationStatus { manager.authorizationStatus }
    var precise: Bool {
        get { manager.desiredAccuracy == kCLLocationAccuracyBest }
        set { manager.desiredAccuracy = newValue ? kCLLocationAccuracyBest : kCLLocationAccuracyHundredMeters }
    }
    func ask() { manager.requestWhenInUseAuthorization() }
    func start() { manager.startUpdatingLocation() }
    func stop() { manager.stopUpdatingLocation() }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) { statusChanged?() }
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        if let last = locations.last { found?(last) }
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) { failed?(error) }
}

@MainActor
final class SiteLocation {
    static let shared = SiteLocation()

    /// Makes the locator the first time one is needed. A test run gets none,
    /// so CoreLocation is never touched there; tests put in their own.
    var makeLocator: @MainActor () -> Locating? = { Store.testing ? nil : CoreLocator() }
    /// Told when macOS refuses Search the location, so the page you allowed
    /// isn't simply left with an error and no reason.
    var refused: (@MainActor () -> Void)? = { Browsers.front?.announce("macOS isn't sharing your location with Search") }

    private var locator: Locating?
    /// The geolocation managers waiting for a position (one per process pool).
    private var waiting: [Ref] = []
    private var precise = false
    private var told = false
    /// Every manager the provider was set on.
    private var provided: [Ref] = []

    /// WKGeolocationProviderV1, laid out by hand: a version (int), the
    /// client's pointer, then startUpdating, stopUpdating and
    /// setEnableHighAccuracy.
    private static let provider: UnsafeMutableRawPointer = {
        let start: @convention(c) (Ref?, UnsafeRawPointer?) -> Void = { manager, _ in
            guard let manager else { return }
            SiteLocation.onMain { SiteLocation.shared.start(manager) }
        }
        let stop: @convention(c) (Ref?, UnsafeRawPointer?) -> Void = { manager, _ in
            guard let manager else { return }
            SiteLocation.onMain { SiteLocation.shared.stop(manager) }
        }
        let accuracy: @convention(c) (Ref?, Bool, UnsafeRawPointer?) -> Void = { _, on, _ in
            SiteLocation.onMain { SiteLocation.shared.setPrecise(on) }
        }
        let table = UnsafeMutableRawPointer.allocate(byteCount: 16 + 3 * 8, alignment: 8)
        table.storeBytes(of: Int32(1), toByteOffset: 0, as: Int32.self)
        table.storeBytes(of: nil, toByteOffset: 8, as: UnsafeRawPointer?.self)
        table.storeBytes(of: unsafeBitCast(start, to: UnsafeRawPointer.self), toByteOffset: 16, as: UnsafeRawPointer.self)
        table.storeBytes(of: unsafeBitCast(stop, to: UnsafeRawPointer.self), toByteOffset: 24, as: UnsafeRawPointer.self)
        table.storeBytes(of: unsafeBitCast(accuracy, to: UnsafeRawPointer.self), toByteOffset: 32, as: UnsafeRawPointer.self)
        return table
    }()

    nonisolated private static func onMain(_ work: @escaping @MainActor () -> Void) {
        if Thread.isMainThread { MainActor.assumeIsolated(work) } else { DispatchQueue.main.async { work() } }
    }

    /// Set on a process pool's geolocation manager, once. Nothing here asks
    /// macOS anything.
    nonisolated static func provide(_ pool: WKProcessPool) {
        onMain {
            guard let c = GeolocationC.loaded,
                  let manager = c.manager(UnsafeRawPointer(Unmanaged.passUnretained(pool).toOpaque())),
                  !shared.provided.contains(manager) else { return }
            shared.provided.append(manager)
            c.setProvider(manager, provider)
        }
    }

    // MARK: - WebKit's calls

    func start(_ manager: UnsafeRawPointer) {
        if !waiting.contains(manager) { waiting.append(manager) }
        told = false
        if locator == nil {
            locator = makeLocator()
            locator?.statusChanged = { [weak self] in self?.statusChanged() }
            locator?.found = { [weak self] in self?.found($0) }
            locator?.failed = { [weak self] in self?.failed($0) }
        }
        guard let locator else { return fail() }
        locator.precise = precise
        switch locator.status {
        case .notDetermined: locator.ask()
        case .denied, .restricted: refuse()
        default: locator.start()
        }
    }

    func stop(_ manager: UnsafeRawPointer) {
        waiting.removeAll { $0 == manager }
        if waiting.isEmpty { locator?.stop() }
    }

    func setPrecise(_ on: Bool) {
        precise = on
        locator?.precise = on
    }

    // MARK: - CoreLocation's answers

    private func statusChanged() {
        guard !waiting.isEmpty, let locator else { return }
        switch locator.status {
        case .notDetermined: break
        case .denied, .restricted: refuse()
        default: locator.start()
        }
    }

    private func found(_ place: CLLocation) {
        guard let c = GeolocationC.loaded, !waiting.isEmpty else { return }
        let altitude = place.verticalAccuracy >= 0
        let heading = place.course >= 0
        let speed = place.speed >= 0
        guard let position = c.position(place.timestamp.timeIntervalSince1970,
                                        place.coordinate.latitude, place.coordinate.longitude, max(place.horizontalAccuracy, 0),
                                        altitude, place.altitude, altitude, place.verticalAccuracy,
                                        heading, place.course, speed, place.speed) else { return }
        defer { c.release(position) }
        for manager in waiting { c.changed(manager, position) }
    }

    private func failed(_ error: Error) {
        // Not known yet is CoreLocation still looking: it keeps trying.
        if (error as? CLError)?.code == .locationUnknown { return }
        if (error as? CLError)?.code == .denied { return refuse() }
        fail()
    }

    /// macOS said no, now or before: the page is told, and you once.
    private func refuse() {
        if !told { told = true; refused?() }
        fail()
    }

    private func fail() {
        guard let c = GeolocationC.loaded else { return }
        for manager in waiting { c.failed(manager) }
    }
}
