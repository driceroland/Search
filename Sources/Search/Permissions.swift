import SwiftUI
import AppKit
import WebKit
import UserNotifications

// MARK: - Permission Types & States

enum PermissionType: String, CaseIterable, Identifiable, Codable {
    case notifications = "notifications"
    case camera = "camera"
    case microphone = "microphone"
    case geolocation = "geolocation"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .notifications: return "Notificaciones"
        case .camera: return "Cámara"
        case .microphone: return "Micrófono"
        case .geolocation: return "Ubicación"
        }
    }

    var icon: String {
        switch self {
        case .notifications: return "bell.badge"
        case .camera: return "video"
        case .microphone: return "mic"
        case .geolocation: return "location"
        }
    }
}

enum PermissionState: String, CaseIterable, Identifiable, Codable {
    case allow = "allow"
    case deny = "deny"
    case ask = "ask"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .allow: return "Permitir"
        case .deny: return "Bloquear"
        case .ask: return "Preguntar"
        }
    }

    var jsValue: String {
        switch self {
        case .allow: return "granted"
        case .deny: return "denied"
        case .ask: return "default"
        }
    }
}

// MARK: - Permissions Store

@MainActor
final class Permissions: ObservableObject {
    static let shared = Permissions()

    /// Stored as [host: [permissionType: permissionState]]
    @Published private(set) var records: [String: [String: String]] = [:]

    private static var file: URL { Store.file("permissions.json") }

    init() {
        load()
        migrateCaptureSettings()
    }

    func state(for type: PermissionType, on host: String) -> PermissionState {
        let clean = cleanHost(host)
        guard let hostRecords = records[clean],
              let val = hostRecords[type.rawValue],
              let state = PermissionState(rawValue: val) else {
            return .ask
        }
        return state
    }

    func set(state: PermissionState, for type: PermissionType, on host: String) {
        let clean = cleanHost(host)
        guard !clean.isEmpty else { return }

        var hostRecords = records[clean] ?? [:]
        if state == .ask {
            hostRecords.removeValue(forKey: type.rawValue)
        } else {
            hostRecords[type.rawValue] = state.rawValue
        }

        if hostRecords.isEmpty {
            records.removeValue(forKey: clean)
        } else {
            records[clean] = hostRecords
        }
        save()

        // Sync with legacy capture.* keys in Store.settings for camera/mic
        if type == .camera {
            let key = "\(clean)|1"
            if state == .ask {
                Store.settings.removeObject(forKey: "capture." + key)
            } else {
                Store.settings.set(state == .allow, forKey: "capture." + key)
            }
        } else if type == .microphone {
            let key = "\(clean)|2"
            if state == .ask {
                Store.settings.removeObject(forKey: "capture." + key)
            } else {
                Store.settings.set(state == .allow, forKey: "capture." + key)
            }
        }

        if type == .notifications && state == .allow {
            Task {
                _ = await NotificationManager.shared.requestSystemAuthorization()
            }
        }
    }

    func remove(host: String) {
        let clean = cleanHost(host)
        records.removeValue(forKey: clean)
        save()
        for key in Store.settings.dictionaryRepresentation().keys where key.hasPrefix("capture.\(clean)|") {
            Store.settings.removeObject(forKey: key)
        }
    }

    func resetAll() {
        records = [:]
        save()
        for key in Store.settings.dictionaryRepresentation().keys where key.hasPrefix("capture.") {
            Store.settings.removeObject(forKey: key)
        }
    }

    func hosts() -> [String] {
        records.keys.sorted()
    }

    func hasActivePermission(for host: String) -> Bool {
        let clean = cleanHost(host)
        guard let hostRecords = records[clean] else { return false }
        return !hostRecords.isEmpty
    }

    func cleanHost(_ host: String) -> String {
        var h = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if h.hasPrefix("https://") { h = String(h.dropFirst(8)) }
        if h.hasPrefix("http://") { h = String(h.dropFirst(7)) }
        if let slash = h.firstIndex(of: "/") { h = String(h[..<slash]) }
        if let colon = h.firstIndex(of: ":") { h = String(h[..<colon]) }
        return h
    }

    private func load() {
        guard let data = try? Data(contentsOf: Permissions.file),
              let dict = try? JSONDecoder().decode([String: [String: String]].self, from: data) else {
            return
        }
        records = dict
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? FileManager.default.createDirectory(at: Store.folder, withIntermediateDirectories: true)
        try? data.write(to: Permissions.file, options: .atomic)
    }

    private func migrateCaptureSettings() {
        for (key, val) in Store.settings.dictionaryRepresentation() where key.hasPrefix("capture.") {
            let remainder = String(key.dropFirst("capture.".count))
            let parts = remainder.split(separator: "|")
            guard parts.count == 2, let allowed = val as? Bool else { continue }
            let host = cleanHost(String(parts[0]))
            let typeCode = String(parts[1])
            let pType: PermissionType? = typeCode == "2" ? .microphone : (typeCode == "1" ? .camera : nil)
            guard let pType else { continue }
            if state(for: pType, on: host) == .ask {
                var hostDict = records[host] ?? [:]
                hostDict[pType.rawValue] = allowed ? PermissionState.allow.rawValue : PermissionState.deny.rawValue
                records[host] = hostDict
            }
        }
        save()
    }

    /// User script that polyfills HTML5 Notification API and navigator.permissions.
    var script: String {
        var map: [String: String] = [:]
        for (host, perms) in records {
            if let notifState = perms[PermissionType.notifications.rawValue] {
                map[host] = PermissionState(rawValue: notifState)?.jsValue ?? "default"
            }
        }
        let jsonStr: String
        if let data = try? JSONSerialization.data(withJSONObject: map, options: []),
           let str = String(data: data, encoding: .utf8) {
            jsonStr = str
        } else {
            jsonStr = "{}"
        }

        return """
        (function() {
          if (window.__searchNotificationInjected) return;
          window.__searchNotificationInjected = true;

          var __permsMap = \(jsonStr);
          var __host = window.location.host;
          var __initial = __permsMap[__host] || "default";

          function WebKitNotification(title, options) {
            options = options || {};
            this.title = title || "";
            this.body = options.body || "";
            this.icon = options.icon || "";
            this.tag = options.tag || "";
            this.data = options.data || null;

            if (WebKitNotification.permission === "granted") {
              try {
                window.webkit.messageHandlers.officeNotificationPost.postMessage({
                  title: this.title,
                  body: this.body,
                  icon: this.icon,
                  tag: this.tag,
                  host: window.location.host
                });
              } catch(e) {}
            }
          }

          WebKitNotification.permission = __initial;
          WebKitNotification.maxActions = 2;

          WebKitNotification.requestPermission = function(callback) {
            return new Promise(function(resolve, reject) {
              window.__pendingNotifyQueue = window.__pendingNotifyQueue || [];
              window.__pendingNotifyQueue.push({ resolve: resolve, callback: callback });
              try {
                window.webkit.messageHandlers.officeNotificationAsk.postMessage({
                  host: window.location.host
                });
              } catch (e) {
                resolve(WebKitNotification.permission);
                if (typeof callback === "function") callback(WebKitNotification.permission);
              }
            });
          };

          window.Notification = WebKitNotification;

          if (window.ServiceWorkerRegistration && window.ServiceWorkerRegistration.prototype) {
            window.ServiceWorkerRegistration.prototype.showNotification = function(title, options) {
              options = options || {};
              if (WebKitNotification.permission === "granted") {
                try {
                  window.webkit.messageHandlers.officeNotificationPost.postMessage({
                    title: title || "",
                    body: options.body || "",
                    icon: options.icon || "",
                    tag: options.tag || "",
                    host: window.location.host
                  });
                } catch(e) {}
                return Promise.resolve();
              }
              return Promise.reject(new TypeError("Notification permission not granted"));
            };
          }

          if (navigator.permissions && navigator.permissions.query) {
            var origQuery = navigator.permissions.query.bind(navigator.permissions);
            navigator.permissions.query = function(desc) {
              if (desc && desc.name === "notifications") {
                var state = WebKitNotification.permission === "default" ? "prompt" : WebKitNotification.permission;
                return Promise.resolve({
                  state: state,
                  name: "notifications",
                  onchange: null
                });
              }
              return origQuery(desc);
            };
          }

          window.__searchSetNotificationPermission = function(perm) {
            WebKitNotification.permission = perm;
            var q = window.__pendingNotifyQueue || [];
            window.__pendingNotifyQueue = [];
            q.forEach(function(item) {
              if (item.resolve) item.resolve(perm);
              if (typeof item.callback === "function") item.callback(perm);
            });
          };
        })();
        """
    }
}

// MARK: - Native Notification Manager

final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()

    weak var browser: Browser?

    func setup() {
        UNUserNotificationCenter.current().delegate = self
    }

    func requestSystemAuthorization() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            return false
        }
    }

    func post(title: String, body: String, subtitle: String?, host: String, tag: String?) {
        Task { @MainActor in
            guard Permissions.shared.state(for: .notifications, on: host) == .allow else { return }

            _ = await requestSystemAuthorization()

            let content = UNMutableNotificationContent()
            content.title = title.isEmpty ? host : title
            if let subtitle = subtitle, !subtitle.isEmpty, subtitle != title {
                content.subtitle = subtitle
            }
            content.body = body
            content.sound = .default
            content.userInfo = ["host": host]

            let id = (tag != nil && !tag!.isEmpty) ? "\(host).\(tag!)" : UUID().uuidString
            let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
            try? await UNUserNotificationCenter.current().add(request)
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Show banner and play sound even when the app is active
        completionHandler([.banner, .sound, .badge])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        if let host = userInfo["host"] as? String {
            Task { @MainActor in
                NSApp.activate(ignoringOtherApps: true)
                Links.window?.makeKeyAndOrderFront(nil)
                browser?.focusTab(withHost: host)
            }
        }
        completionHandler()
    }
}

// MARK: - Notification Script Message Handler

final class NotificationRelay: NSObject, WKScriptMessageHandler {
    static let askName = "officeNotificationAsk"
    static let postName = "officeNotificationPost"

    weak var tab: Tab?
    weak var browser: Browser?

    func userContentController(
        _ controller: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let body = message.body as? [String: Any] else { return }
        let rawHost = (body["host"] as? String) ?? (tab?.address?.host() ?? "")
        let host = Permissions.shared.cleanHost(rawHost)
        guard !host.isEmpty else { return }

        if message.name == NotificationRelay.askName {
            MainActor.assumeIsolated {
                browser?.handleNotificationPermissionRequest(host: host, for: tab)
            }
        } else if message.name == NotificationRelay.postName {
            let title = body["title"] as? String ?? ""
            let bodyText = body["body"] as? String ?? ""
            let tag = body["tag"] as? String
            MainActor.assumeIsolated {
                NotificationManager.shared.post(
                    title: title,
                    body: bodyText,
                    subtitle: host,
                    host: host,
                    tag: tag
                )
            }
        }
    }
}

// MARK: - Site Permissions Popover (Toolbar)

struct SitePermissionsPopover: View {
    @ObservedObject var browser: Browser
    let host: String
    weak var tab: Tab?
    @ObservedObject private var permissions = Permissions.shared

    var body: some View {
        let clean = permissions.cleanHost(host)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Mark(icon: tab?.icon, letter: tab?.monogram ?? "•", size: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(clean)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.green)
                        Text("Conexión segura")
                            .font(.system(size: 10.5))
                            .foregroundStyle(Palette.muted)
                    }
                }
                Spacer(minLength: 4)
            }
            .padding(.bottom, 2)

            Divider()
                .background(Palette.hairline)

            VStack(spacing: 6) {
                permissionRow(for: .notifications, host: clean)
                permissionRow(for: .camera, host: clean)
                permissionRow(for: .microphone, host: clean)
            }

            Divider()
                .background(Palette.hairline)

            HStack {
                Button("Restablecer") {
                    permissions.remove(host: clean)
                    browser.syncPermissionsToTabs()
                    browser.announce("Permisos restablecidos para \(clean)")
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(Palette.muted)

                Spacer()

                Button("Recargar página") {
                    tab?.reload()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.ink)
            }
        }
        .padding(14)
        .frame(width: 270)
    }

    private func permissionRow(for type: PermissionType, host: String) -> some View {
        let current = permissions.state(for: type, on: host)
        return HStack(spacing: 8) {
            Image(systemName: type.icon)
                .font(.system(size: 12))
                .foregroundStyle(current == .allow ? Color.accentColor : Palette.muted)
                .frame(width: 18)

            Text(type.title)
                .font(.system(size: 12))
                .foregroundStyle(Palette.ink)

            Spacer()

            Menu {
                Button {
                    update(type: type, state: .allow, host: host)
                } label: {
                    HStack {
                        Text("Permitir")
                        if current == .allow { Text("✓") }
                    }
                }
                Button {
                    update(type: type, state: .deny, host: host)
                } label: {
                    HStack {
                        Text("Bloquear")
                        if current == .deny { Text("✓") }
                    }
                }
                Button {
                    update(type: type, state: .ask, host: host)
                } label: {
                    HStack {
                        Text("Preguntar")
                        if current == .ask { Text("✓") }
                    }
                }
            } label: {
                Text(current.title)
                    .font(.system(size: 11))
                    .foregroundStyle(current == .allow ? Palette.ink : Palette.muted)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.vertical, 2)
    }

    private func update(type: PermissionType, state: PermissionState, host: String) {
        permissions.set(state: state, for: type, on: host)
        browser.syncPermissionsToTabs()
        if type == .notifications {
            tab?.built?.evaluateJavaScript(
                "if (window.__searchSetNotificationPermission) window.__searchSetNotificationPermission('\(state.jsValue)');",
                completionHandler: nil
            )
        }
    }
}

// MARK: - Site Permissions Settings View (SettingsPanel)

struct SitePermissionsSettingsView: View {
    @ObservedObject var browser: Browser
    @ObservedObject private var permissions = Permissions.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Permisos de sitios")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                    Text("Configura qué sitios pueden mostrar notificaciones o usar la cámara y el micrófono")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.muted)
                }
                Spacer()
                if !permissions.hosts().isEmpty {
                    Pill("Restablecer todos") {
                        permissions.resetAll()
                        browser.syncPermissionsToTabs()
                        browser.announce("Todos los permisos han sido restablecidos")
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            if permissions.hosts().isEmpty {
                Rule()
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.shield")
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.muted)
                    Text("Ningún sitio ha solicitado permisos todavía.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.muted)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            } else {
                ForEach(permissions.hosts(), id: \.self) { host in
                    Rule()
                    SitePermissionSettingRow(browser: browser, host: host)
                }
            }
        }
    }
}

private struct SitePermissionSettingRow: View {
    @ObservedObject var browser: Browser
    let host: String
    @ObservedObject private var permissions = Permissions.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(host)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Palette.ink)
                Spacer()
                Button {
                    permissions.remove(host: host)
                    browser.syncPermissionsToTabs()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.muted)
                }
                .buttonStyle(.plain)
                .help("Eliminar permisos para \(host)")
            }

            HStack(spacing: 14) {
                settingBadge(for: .notifications)
                settingBadge(for: .camera)
                settingBadge(for: .microphone)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func settingBadge(for type: PermissionType) -> some View {
        let current = permissions.state(for: type, on: host)
        return Menu {
            Button("Permitir") {
                permissions.set(state: .allow, for: type, on: host)
                browser.syncPermissionsToTabs()
            }
            Button("Bloquear") {
                permissions.set(state: .deny, for: type, on: host)
                browser.syncPermissionsToTabs()
            }
            Button("Preguntar") {
                permissions.set(state: .ask, for: type, on: host)
                browser.syncPermissionsToTabs()
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: type.icon)
                    .font(.system(size: 10))
                Text("\(type.title): \(current.title)")
                    .font(.system(size: 10.5))
            }
            .foregroundStyle(current == .allow ? Palette.ink : Palette.muted)
            .padding(.horizontal, 6)
            .padding(.vertical, 2.5)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(current == .allow ? Palette.wash : Palette.hover)
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}
