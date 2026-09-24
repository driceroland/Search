#ifndef SEARCH_WEBKITGTK_SHIM_H
#define SEARCH_WEBKITGTK_SHIM_H

// GTK 4 and WebKitGTK 6.0, for Swift. Most of both imports as it is; what
// doesn't is macros (the casts, g_signal_connect) and variadic functions
// (g_object_new), and those are written out once here as functions.

#include <webkit/webkit.h>

/// `release` is called with `data` once the handler is gone, which is when
/// the object it was connected to is: that is how the Swift closure behind a
/// signal is let go of.
static inline gulong search_connect(gpointer instance, const char *signal, GCallback callback,
                                    gpointer data, GClosureNotify release) {
    return g_signal_connect_data(instance, signal, callback, data, release, (GConnectFlags)0);
}

static inline GtkWidget *search_web_view_new(WebKitNetworkSession *session, WebKitUserContentManager *content) {
    return GTK_WIDGET(g_object_new(WEBKIT_TYPE_WEB_VIEW,
                                   "network-session", session,
                                   "user-content-manager", content,
                                   NULL));
}

/// A view opened by a page (window.open, a link with a target) has to share
/// its opener's web process and settings, so WebKit asks for it to be made
/// from the opener.
static inline GtkWidget *search_web_view_related(WebKitWebView *opener) {
    return GTK_WIDGET(g_object_new(WEBKIT_TYPE_WEB_VIEW,
                                   "related-view", opener,
                                   NULL));
}

static inline GtkWidget *search_widget(gpointer object) { return GTK_WIDGET(object); }
static inline GtkWindow *search_window(gpointer object) { return GTK_WINDOW(object); }
static inline GtkBox *search_box(gpointer object) { return GTK_BOX(object); }
static inline GtkButton *search_button(gpointer object) { return GTK_BUTTON(object); }
static inline GtkEditable *search_editable(gpointer object) { return GTK_EDITABLE(object); }
static inline GtkEntry *search_entry(gpointer object) { return GTK_ENTRY(object); }
static inline GtkLabel *search_label(gpointer object) { return GTK_LABEL(object); }
static inline GtkStack *search_stack(gpointer object) { return GTK_STACK(object); }
static inline GtkOverlay *search_overlay(gpointer object) { return GTK_OVERLAY(object); }
static inline GtkHeaderBar *search_header_bar(gpointer object) { return GTK_HEADER_BAR(object); }
static inline GtkScrolledWindow *search_scrolled(gpointer object) { return GTK_SCROLLED_WINDOW(object); }
static inline GtkGesture *search_gesture(gpointer object) { return GTK_GESTURE(object); }
static inline GtkGestureSingle *search_gesture_single(gpointer object) { return GTK_GESTURE_SINGLE(object); }
static inline GtkEventController *search_controller(gpointer object) { return GTK_EVENT_CONTROLLER(object); }
static inline GApplication *search_application(gpointer object) { return G_APPLICATION(object); }
static inline WebKitWebView *search_web_view(gpointer object) { return WEBKIT_WEB_VIEW(object); }

#endif
