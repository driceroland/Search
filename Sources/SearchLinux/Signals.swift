import CWebKitGTK

// GObject signals, for Swift closures.
//
// A signal calls a C function with a pointer of our choosing at the end. The
// pointer is a box holding the closure; the box is retained for as long as
// the handler is connected and released by GLib when the object goes, so a
// closed tab takes its handlers with it. The C function differs only by what
// the signal hands over before the pointer, hence one `on` per shape.

private final class Box<Body> {
    let body: Body
    init(_ body: Body) { self.body = body }
}

private func connect<Body>(_ object: UnsafeMutableRawPointer?, _ signal: String, _ callback: GCallback, _ body: Body) {
    let box = Unmanaged.passRetained(Box(body)).toOpaque()
    _ = search_connect(object, signal, callback, box) { data, _ in
        guard let data else { return }
        Unmanaged<AnyObject>.fromOpaque(data).release()
    }
}

private func body<Body>(_ data: UnsafeMutableRawPointer?) -> Body {
    Unmanaged<Box<Body>>.fromOpaque(data!).takeUnretainedValue().body
}

typealias Raw = UnsafeMutableRawPointer

/// `clicked`, `activate`, `close`, `destroy`: nothing but the object.
func on(_ object: Raw?, _ signal: String, _ run: @escaping () -> Void) {
    let call: @convention(c) (Raw?, Raw?) -> Void = { _, data in
        (body(data) as () -> Void)()
    }
    connect(object, signal, unsafeBitCast(call, to: GCallback.self), run)
}

/// `notify::<property>`: the object and the property that changed.
func onNotify(_ object: Raw?, _ property: String, _ run: @escaping () -> Void) {
    onDetail(object, "notify::" + property, run)
}

/// Signals that hand over one pointer after the object, when it isn't wanted:
/// `notify` (the property), a GSettings' `changed` (the key).
func onDetail(_ object: Raw?, _ signal: String, _ run: @escaping () -> Void) {
    let call: @convention(c) (Raw?, Raw?, Raw?) -> Void = { _, _, data in
        (body(data) as () -> Void)()
    }
    connect(object, signal, unsafeBitCast(call, to: GCallback.self), run)
}

/// Signals whose answer is whether they were handled: `close-request`.
func onAsk(_ object: Raw?, _ signal: String, _ run: @escaping () -> Bool) {
    let call: @convention(c) (Raw?, Raw?) -> gboolean = { _, data in
        (body(data) as () -> Bool)() ? 1 : 0
    }
    connect(object, signal, unsafeBitCast(call, to: GCallback.self), run)
}

/// `key-pressed` on a key controller: the key, and the modifiers held.
func onKey(_ controller: Raw?, _ run: @escaping (_ key: guint, _ state: GdkModifierType) -> Bool) {
    let call: @convention(c) (Raw?, guint, guint, GdkModifierType, Raw?) -> gboolean = { _, key, _, state, data in
        (body(data) as (guint, GdkModifierType) -> Bool)(key, state) ? 1 : 0
    }
    connect(controller, "key-pressed", unsafeBitCast(call, to: GCallback.self), run)
}

/// `pressed` on a click gesture.
func onPress(_ gesture: Raw?, _ run: @escaping () -> Void) {
    let call: @convention(c) (Raw?, gint, gdouble, gdouble, Raw?) -> Void = { _, _, _, _, data in
        (body(data) as () -> Void)()
    }
    connect(gesture, "pressed", unsafeBitCast(call, to: GCallback.self), run)
}

/// A web view's `load-changed`.
func onLoad(_ view: Raw?, _ run: @escaping (WebKitLoadEvent) -> Void) {
    let call: @convention(c) (Raw?, WebKitLoadEvent, Raw?) -> Void = { _, event, data in
        (body(data) as (WebKitLoadEvent) -> Void)(event)
    }
    connect(view, "load-changed", unsafeBitCast(call, to: GCallback.self), run)
}

/// A web view's `create`: a page asking for a window of its own. The answer
/// is the view it should load into.
func onCreate(_ view: Raw?, _ run: @escaping () -> UnsafeMutablePointer<GtkWidget>?) {
    let call: @convention(c) (Raw?, Raw?, Raw?) -> UnsafeMutablePointer<GtkWidget>? = { _, _, data in
        (body(data) as () -> UnsafeMutablePointer<GtkWidget>?)()
    }
    connect(view, "create", unsafeBitCast(call, to: GCallback.self), run)
}

/// Pointers of every kind GTK hands out, as the untyped pointer GObject
/// functions take.
func raw<T>(_ pointer: UnsafeMutablePointer<T>?) -> Raw? { pointer.map(Raw.init) }
func raw(_ pointer: OpaquePointer?) -> Raw? { pointer.map(Raw.init) }
