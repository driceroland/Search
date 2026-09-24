import CWebKitGTK

// The Mac's colours (Design.swift), as GTK's CSS: white ground and one grey
// pill for the tab you are on, a hairline under the row, and the same greys
// turned over for a dark window.
//
// Dark follows the desktop's own switch, org.gnome.desktop.interface's
// color-scheme, where there is one; GTK 4.14 won't read it by itself.

enum Look {
    private static let css = """
    window.search headerbar { background: #ffffff; box-shadow: none; border-bottom: 1px solid #e8e8e8; min-height: 38px; padding: 0 6px; }
    window.search button.tab { background: none; border: none; box-shadow: none; color: #8c8c8c; padding: 3px 12px; margin: 0 1px; border-radius: 8px; font-weight: 500; min-height: 0; }
    window.search button.tab:hover { background: #f6f6f6; color: #171717; }
    window.search button.tab.current { background: #efefef; color: #171717; }
    window.search .field { background: #ffffff; border: 1px solid #e8e8e8; border-radius: 14px; padding: 10px; margin-top: 80px; box-shadow: 0 12px 40px rgba(0,0,0,0.12); }
    window.search .field entry { background: none; border: none; box-shadow: none; outline: none; font-size: 17px; min-width: 520px; color: #171717; }
    window.search .field entry.refused { color: #b4530a; }

    window.search.dark headerbar { background: #1c1c1c; border-bottom-color: #333333; }
    window.search.dark button.tab { color: #949494; }
    window.search.dark button.tab:hover { background: #262626; color: #ededed; }
    window.search.dark button.tab.current { background: #2d2d2d; color: #ededed; }
    window.search.dark .field { background: #1c1c1c; border-color: #333333; box-shadow: 0 12px 40px rgba(0,0,0,0.5); }
    window.search.dark .field entry { color: #ededed; }
    window.search.dark .field entry.refused { color: #fabf24; }
    """

    static func apply(to window: UnsafeMutablePointer<GtkWidget>) {
        let provider = gtk_css_provider_new()
        gtk_css_provider_load_from_string(provider, css)
        gtk_style_context_add_provider_for_display(
            gdk_display_get_default(), OpaquePointer(provider), guint(GTK_STYLE_PROVIDER_PRIORITY_APPLICATION)
        )
        gtk_widget_add_css_class(window, "search")

        guard let source = g_settings_schema_source_get_default(),
              let schema = g_settings_schema_source_lookup(source, "org.gnome.desktop.interface", 1)
        else { return }
        defer { g_settings_schema_unref(schema) }
        guard g_settings_schema_has_key(schema, "color-scheme") != 0,
              let settings = g_settings_new("org.gnome.desktop.interface")
        else { return }
        let follow = {
            let scheme = g_settings_get_string(settings, "color-scheme")
            let dark = scheme.map { String(cString: $0) == "prefer-dark" } ?? false
            g_free(scheme)
            if dark { gtk_widget_add_css_class(window, "dark") } else { gtk_widget_remove_css_class(window, "dark") }
            gtk_settings_set_prefer_dark(dark)
        }
        follow()
        // Kept for as long as the window: the signal is the settings object's.
        onDetail(raw(settings), "changed::color-scheme") { follow() }
    }
}

private func gtk_settings_set_prefer_dark(_ dark: Bool) {
    guard let settings = gtk_settings_get_default() else { return }
    var value = GValue()
    g_value_init(&value, GType(5 << 2))  // G_TYPE_BOOLEAN
    g_value_set_boolean(&value, dark ? 1 : 0)
    g_object_set_property(UnsafeMutablePointer<GObject>(settings), "gtk-application-prefer-dark-theme", &value)
    g_value_unset(&value)
}
