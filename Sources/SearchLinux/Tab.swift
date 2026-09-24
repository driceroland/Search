import CWebKitGTK
import Foundation

// One web view per tab, as on the Mac, and made only when the tab is first
// shown: a tab brought back from last session is an address and a title
// until somebody looks at it, and costs no web process until then.

final class Tab {
    let id = UUID()
    private(set) var url: String
    private(set) var title: String
    private(set) var view: UnsafeMutablePointer<GtkWidget>?

    /// The tab's title in the row across the top.
    let button: UnsafeMutablePointer<GtkWidget>
    private let label: UnsafeMutablePointer<GtkWidget>

    /// The window, told when anything it draws or keeps has changed.
    var changed: () -> Void = {}
    /// A page asking for a window of its own gets a tab next to this one.
    var opened: (Tab) -> Void = { _ in }
    /// window.close() from the page.
    var closed: () -> Void = {}

    init(url: String, title: String = "") {
        self.url = url
        self.title = title
        label = gtk_label_new(nil)
        gtk_label_set_ellipsize(search_label(raw(label)), PANGO_ELLIPSIZE_END)
        gtk_label_set_max_width_chars(search_label(raw(label)), 22)
        button = gtk_button_new()
        gtk_button_set_child(search_button(raw(button)), label)
        gtk_widget_add_css_class(button, "tab")
        gtk_widget_set_focusable(button, 0)
        relabel()
    }

    /// What the tab says: the page's title, or its address before it has one.
    var name: String {
        if !title.isEmpty { return title }
        return URL(string: url).map(Address.pretty) ?? url
    }

    private func relabel() {
        gtk_label_set_text(search_label(raw(label)), name)
        gtk_widget_set_tooltip_text(button, name)
    }

    /// The view, made now if it hasn't been. A view WebKit already made for a
    /// page's window.open comes in as `made` and is loaded by WebKit itself.
    @discardableResult
    func build(session: OpaquePointer?, content: OpaquePointer?, made: UnsafeMutablePointer<GtkWidget>? = nil) -> UnsafeMutablePointer<GtkWidget> {
        if let view { return view }
        let view = made ?? search_web_view_new(session, content)!
        self.view = view
        gtk_widget_set_hexpand(view, 1)
        gtk_widget_set_vexpand(view, 1)
        let page = search_web_view(raw(view))

        let settings = webkit_web_view_get_settings(page)
        webkit_settings_set_enable_developer_extras(settings, 1)

        onNotify(raw(view), "title") { [weak self] in
            guard let self, let text = webkit_web_view_get_title(page) else { return }
            self.title = String(cString: text)
            self.relabel()
            self.changed()
        }
        onNotify(raw(view), "uri") { [weak self] in
            guard let self, let text = webkit_web_view_get_uri(page) else { return }
            self.url = String(cString: text)
            if self.title.isEmpty { self.relabel() }
            self.changed()
        }
        onCreate(raw(view)) { [weak self] in
            guard let self else { return nil }
            let child = search_web_view_related(page)!
            let tab = Tab(url: "", title: "")
            tab.build(session: nil, content: nil, made: child)
            self.opened(tab)
            return child
        }
        on(raw(view), "close") { [weak self] in self?.closed() }

        if made == nil, !url.isEmpty {
            webkit_web_view_load_uri(page, url)
        }
        return view
    }

    func load(_ address: URL) {
        url = address.absoluteString
        title = ""
        relabel()
        if let view { webkit_web_view_load_uri(search_web_view(raw(view)), url) }
    }

    func back() { view.map { webkit_web_view_go_back(search_web_view(raw($0))) } }
    func forward() { view.map { webkit_web_view_go_forward(search_web_view(raw($0))) } }
    func reload() { view.map { webkit_web_view_reload(search_web_view(raw($0))) } }

    func mark(current: Bool) {
        if current {
            gtk_widget_add_css_class(button, "current")
        } else {
            gtk_widget_remove_css_class(button, "current")
        }
    }
}
