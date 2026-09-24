import CWebKitGTK
import Foundation

// The window: a row of tabs where the title would be, the page under it, and
// the field floating over the page when it's asked for. Everything the Mac's
// Browser knows about which tabs exist and which one is showing, for as much
// as this port does so far (see PORTING.md).

final class Browser {
    private let window: UnsafeMutablePointer<GtkWidget>
    private let strip: UnsafeMutablePointer<GtkWidget>
    private let stage: UnsafeMutablePointer<GtkWidget>
    private let field: UnsafeMutablePointer<GtkWidget>
    private let entry: UnsafeMutablePointer<GtkWidget>

    private let session: OpaquePointer?
    private let content: OpaquePointer?

    private var tabs: [Tab] = []
    private var current: Tab?
    /// The field was asked for with Ctrl+T: Return makes a new tab rather
    /// than sending this one somewhere else. There is no empty tab in
    /// between, because there is no start page to show in it.
    private var opening = false

    init(application: UnsafeMutablePointer<GtkApplication>) {
        window = gtk_application_window_new(application)
        gtk_window_set_title(search_window(raw(window)), "Search")
        gtk_window_set_default_size(search_window(raw(window)), 1280, 820)

        // WebKit's own store for cookies and sign-ins, in the browser's folder.
        session = webkit_network_session_new(Folder.websites, Folder.cache)
        content = webkit_user_content_manager_new()
        Shield.protect(content)

        // The tabs are the title bar, and the title bar is nothing else.
        let header = gtk_header_bar_new()
        strip = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0)
        gtk_widget_set_halign(strip, GTK_ALIGN_START)
        gtk_header_bar_set_title_widget(search_header_bar(raw(header)), strip)
        gtk_widget_set_hexpand(strip, 1)
        gtk_window_set_titlebar(search_window(raw(window)), header)

        stage = gtk_stack_new()
        gtk_stack_set_transition_type(search_stack(raw(stage)), GTK_STACK_TRANSITION_TYPE_NONE)

        entry = gtk_entry_new()
        gtk_entry_set_placeholder_text(search_entry(raw(entry)), "Search or enter address")
        field = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0)
        gtk_widget_add_css_class(field, "field")
        gtk_box_append(search_box(raw(field)), entry)
        gtk_widget_set_halign(field, GTK_ALIGN_CENTER)
        gtk_widget_set_valign(field, GTK_ALIGN_START)
        gtk_widget_set_visible(field, 0)

        let overlay = gtk_overlay_new()
        gtk_overlay_set_child(search_overlay(raw(overlay)), stage)
        gtk_overlay_add_overlay(search_overlay(raw(overlay)), field)
        gtk_window_set_child(search_window(raw(window)), overlay)

        Look.apply(to: window)

        on(raw(entry), "activate") { [weak self] in self?.go() }
        onAsk(raw(window), "close-request") { [weak self] in
            self?.save()
            return false
        }
        listen()
        restore()
        gtk_window_present(search_window(raw(window)))
    }

    // MARK: - tabs

    private func restore() {
        let shape = Session.read()
        for entry in shape.tabs where !entry.url.isEmpty {
            add(Tab(url: entry.url, title: entry.title))
        }
        if tabs.isEmpty {
            ask(opening: true)
        } else {
            show(tabs[min(max(shape.active, 0), tabs.count - 1)])
        }
    }

    private func add(_ tab: Tab, after: Tab? = nil) {
        let at = after.flatMap { a in tabs.firstIndex { $0 === a } }.map { $0 + 1 } ?? tabs.count
        tabs.insert(tab, at: at)
        let previous = at > 0 ? tabs[at - 1].button : nil
        gtk_box_insert_child_after(search_box(raw(strip)), tab.button, previous)

        on(raw(tab.button), "clicked") { [weak self, weak tab] in
            guard let self, let tab else { return }
            // The tab you are on, clicked, is where its address is.
            if tab === self.current { self.ask(opening: false) } else { self.show(tab) }
        }
        let middle = gtk_gesture_click_new()
        gtk_gesture_single_set_button(search_gesture_single(raw(middle)), 2)
        onPress(raw(middle)) { [weak self, weak tab] in
            guard let tab else { return }
            self?.close(tab)
        }
        gtk_widget_add_controller(tab.button, search_controller(raw(middle)))

        tab.changed = { [weak self] in self?.save() }
        tab.opened = { [weak self, weak tab] child in
            guard let self else { return }
            self.add(child, after: tab)
            self.show(child)
        }
        tab.closed = { [weak self, weak tab] in
            guard let tab else { return }
            self?.close(tab)
        }
    }

    private func show(_ tab: Tab) {
        let view = tab.build(session: session, content: content)
        if gtk_widget_get_parent(view) == nil {
            gtk_stack_add_named(search_stack(raw(stage)), view, tab.id.uuidString)
        }
        gtk_stack_set_visible_child(search_stack(raw(stage)), view)
        current?.mark(current: false)
        current = tab
        tab.mark(current: true)
        dismiss()
        gtk_widget_grab_focus(view)
        save()
    }

    private func close(_ tab: Tab) {
        guard let index = tabs.firstIndex(where: { $0 === tab }) else { return }
        tabs.remove(at: index)
        gtk_box_remove(search_box(raw(strip)), tab.button)
        if let view = tab.view { gtk_stack_remove(search_stack(raw(stage)), view) }
        if tab === current {
            current = nil
            if tabs.isEmpty {
                ask(opening: true)
            } else {
                show(tabs[min(index, tabs.count - 1)])
            }
        }
        save()
    }

    private func step(_ by: Int) {
        guard let current, let index = tabs.firstIndex(where: { $0 === current }), tabs.count > 1 else { return }
        show(tabs[(index + by + tabs.count) % tabs.count])
    }

    private func save() {
        let index = current.flatMap { c in tabs.firstIndex { $0 === c } } ?? 0
        Session.write(Session.Shape(
            tabs: tabs.map { Session.Entry(url: $0.url, title: $0.title) },
            active: index
        ))
    }

    // MARK: - the field

    private func ask(opening: Bool) {
        self.opening = opening || current == nil
        let text = self.opening ? "" : (current?.url ?? "")
        gtk_editable_set_text(search_editable(raw(entry)), text)
        gtk_widget_remove_css_class(entry, "refused")
        gtk_widget_set_visible(field, 1)
        gtk_widget_grab_focus(entry)
        gtk_editable_select_region(search_editable(raw(entry)), 0, -1)
    }

    private func dismiss() {
        gtk_widget_set_visible(field, 0)
        if let view = current?.view { gtk_widget_grab_focus(view) }
    }

    /// An address goes there; anything else is words for the search engine,
    /// the Mac's own Address and Engine deciding which.
    private func go() {
        let typed = String(cString: gtk_editable_get_text(search_editable(raw(entry))))
        let engine = Engine.standard.template(custom: "")
        guard let url = Address.url(from: typed) ?? Engine.url(for: typed, template: engine) else {
            gtk_widget_add_css_class(entry, "refused")
            return
        }
        if opening || current == nil {
            let tab = Tab(url: url.absoluteString)
            add(tab, after: current)
            show(tab)
        } else if let current {
            current.load(url)
            dismiss()
        }
        save()
    }

    // MARK: - keys

    /// Ctrl where the Mac has ⌘, and Linux's own keys beside them. Taken
    /// before the page sees them, so a page can't keep Ctrl+L from the field.
    private func listen() {
        let keys = gtk_event_controller_key_new()
        gtk_event_controller_set_propagation_phase(keys, GTK_PHASE_CAPTURE)
        onKey(raw(keys)) { [weak self] key, state in
            self?.press(Int32(key), state) ?? false
        }
        gtk_widget_add_controller(window, keys)
    }

    private func press(_ key: Int32, _ state: GdkModifierType) -> Bool {
        let held = state.rawValue & (GDK_CONTROL_MASK.rawValue | GDK_SHIFT_MASK.rawValue | GDK_ALT_MASK.rawValue)
        let control = held == GDK_CONTROL_MASK.rawValue
        let controlShift = held == GDK_CONTROL_MASK.rawValue | GDK_SHIFT_MASK.rawValue
        let alt = held == GDK_ALT_MASK.rawValue

        switch key {
        case GDK_KEY_Escape where gtk_widget_get_visible(field) != 0:
            guard current != nil else { return true }
            dismiss()
        case GDK_KEY_l where control, GDK_KEY_F6 where held == 0:
            ask(opening: false)
        case GDK_KEY_t where control:
            ask(opening: true)
        case GDK_KEY_w where control:
            if let current { close(current) }
        case GDK_KEY_r where control, GDK_KEY_F5 where held == 0:
            current?.reload()
        case GDK_KEY_Tab where control, GDK_KEY_Page_Down where control:
            step(1)
        case GDK_KEY_ISO_Left_Tab where controlShift, GDK_KEY_Tab where controlShift, GDK_KEY_Page_Up where control:
            step(-1)
        case GDK_KEY_bracketleft where control, GDK_KEY_Left where alt:
            current?.back()
        case GDK_KEY_bracketright where control, GDK_KEY_Right where alt:
            current?.forward()
        case GDK_KEY_1...GDK_KEY_9 where control:
            // ⌘9 is the last tab, as in every browser.
            guard !tabs.isEmpty else { return true }
            show(key == GDK_KEY_9 ? tabs[tabs.count - 1] : tabs[min(Int(key - GDK_KEY_1), tabs.count - 1)])
        case GDK_KEY_q where control:
            save()
            gtk_window_destroy(search_window(raw(window)))
        default:
            return false
        }
        return true
    }
}
