import SwiftUI
import WebKit

/// Application › Service workers, laid out as Chromium's: the page's
/// options at the top, then each registration with its source, status,
/// clients and the push, sync and lifecycle controls.
struct DeveloperServiceWorkersView: View {
    @ObservedObject var session: DeveloperToolsSession
    let refresh: Int

    @State private var listing = DeveloperServiceWorkers.Listing()
    @State private var loaded = false
    @State private var message: String?
    @State private var syncTag: [String: String] = [:]
    @State private var busy: String?
    @State private var tick = 0
    @ObservedObject private var reloads = DeveloperServiceWorkerReloads.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                options
                if let message {
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .padding(DeveloperToolsStyle.gutter)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(DeveloperToolsStyle.raised)
                }
                if !loaded {
                    ProgressView().controlSize(.small).padding().frame(maxWidth: .infinity)
                } else if let note = listing.note {
                    placeholder(note)
                } else if listing.registrations.isEmpty {
                    placeholder("No service workers are registered for this origin.")
                } else {
                    ForEach(listing.registrations) { registration in
                        card(registration)
                    }
                }
            }
        }
        .task(id: "\(refresh)-\(tick)-\(session.web?.url?.absoluteString ?? "")") { await load() }
        // Workers change state on their own (installing, activating).
        .task(id: refresh) {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, busy == nil else { continue }
                await load(quietly: true)
            }
        }
        .onAppear { reloads.watch(session.web) }
        .accessibilityIdentifier("developer-service-workers")
    }

    private var options: some View {
        HStack(spacing: DeveloperToolsStyle.gutter * 2) {
            Toggle("Offline", isOn: Binding(get: { session.throttle == .offline },
                                            set: { session.setNetwork($0 ? .offline : .unrestricted) }))
                .disabled(!session.requestInterception)
                .help("Fail the inspected page’s requests, as the Network panel’s Offline does")
            Toggle("Update on reload", isOn: $reloads.enabled)
                .help("Each time the page loads, its service workers check for a new script and a new worker takes over. Chrome does this before the page loads; WebKit can only do it after, so the new worker controls the next load.")
                .accessibilityIdentifier("developer-worker-update-on-reload")
            // WebKit has no switch that routes a page's requests around its
            // service worker, so this stays off rather than pretend.
            Toggle("Bypass for network", isOn: .constant(false))
                .disabled(true)
                .help("WebKit can’t send a page’s requests past its service worker, so Bypass for network isn’t available. Unregister the worker, or use Clear site data, to load without it.")
            Spacer(minLength: 0)
        }
        .toggleStyle(.developerCheckbox)
        .controlSize(.small)
        .padding(.horizontal, DeveloperToolsStyle.gutter)
        .frame(height: DeveloperToolsStyle.rowHeight + 6)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func card(_ registration: DeveloperWorkerRegistration) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: DeveloperToolsStyle.gutter) {
                Text(registration.scope).font(.system(size: 12, weight: .semibold)).textSelection(.enabled)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                link("Update") { act(.update, registration) }
                link("Unregister") { act(.unregister, registration) }
            }
            if let source = (registration.active ?? registration.waiting ?? registration.installing)?.scriptURL {
                row("Source") {
                    Text(URL(string: source)?.lastPathComponent ?? source)
                        .foregroundStyle(DeveloperToolsStyle.tint)
                        .help(source)
                        .textSelection(.enabled)
                }
            }
            row("Status") {
                VStack(alignment: .leading, spacing: 3) {
                    if let active = registration.active { status(active, text: "activated and is running") }
                    if let waiting = registration.waiting {
                        HStack(spacing: DeveloperToolsStyle.gutter) {
                            status(waiting, text: "waiting to activate")
                            link("skipWaiting") { act(.skipWaiting, registration) }
                        }
                    }
                    if let installing = registration.installing { status(installing, text: "trying to install") }
                    if registration.workers.isEmpty { Text("No worker").foregroundStyle(.secondary) }
                }
            }
            row("Clients") {
                Text(registration.controlsPage ? (session.web?.url?.absoluteString ?? "This page") : "This page isn’t controlled")
                    .foregroundStyle(registration.controlsPage ? Palette.ink : .secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            row("Sync") {
                HStack(spacing: DeveloperToolsStyle.controlSpacing) {
                    TextField("test-tag-from-devtools", text: entry($syncTag, registration.scope))
                        .textFieldStyle(.roundedBorder).controlSize(.small).frame(maxWidth: 320)
                    Button("Sync") { act(.sync, registration, tag: syncTag[registration.scope]) }.controlSize(.small)
                        .disabled(registration.active == nil || busy != nil)
                }
                .help(registration.syncSupported ? "Register a Background Sync" : "WebKit doesn’t support Background Sync")
            }
            row("Update Cycle") {
                Text("updateViaCache: \(registration.updateViaCache)").foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 11))
        .padding(DeveloperToolsStyle.gutter * 1.5)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func status(_ worker: DeveloperWorkerRegistration.Worker, text: String) -> some View {
        HStack(spacing: DeveloperToolsStyle.controlSpacing) {
            Circle().fill(worker.role == "active" ? Color.green : worker.role == "waiting" ? Color.orange : Color.yellow)
                .frame(width: 7, height: 7)
            Text("\(worker.role.capitalized) · \(worker.state) — \(text)")
        }
    }

    private func row<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DeveloperToolsStyle.gutter) {
            Text(label).foregroundStyle(.secondary).frame(width: 90, alignment: .trailing)
            content()
            Spacer(minLength: 0)
        }
    }

    private func link(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).foregroundStyle(DeveloperToolsStyle.tint).underline()
        }
        .buttonStyle(.plain)
        .disabled(busy != nil)
        .accessibilityIdentifier("developer-worker-\(title.lowercased())")
    }

    private func entry(_ state: Binding<[String: String]>, _ key: String) -> Binding<String> {
        Binding(get: { state.wrappedValue[key] ?? "" }, set: { state.wrappedValue[key] = $0 })
    }

    private func placeholder(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary).padding(DeveloperToolsStyle.gutter * 3).frame(maxWidth: .infinity)
    }

    private func load(quietly: Bool = false) async {
        guard let web = session.web else { return }
        do {
            let fresh = try await DeveloperServiceWorkers.list(in: web)
            if fresh.registrations != listing.registrations || fresh.note != listing.note { listing = fresh }
            loaded = true
        } catch {
            if !quietly { message = error.localizedDescription }
            loaded = true
        }
    }

    private func act(_ action: DeveloperServiceWorkers.Action, _ registration: DeveloperWorkerRegistration, tag: String? = nil) {
        guard let web = session.web else { return }
        busy = registration.scope
        message = nil
        Task {
            defer { busy = nil; tick += 1 }
            do {
                try await DeveloperServiceWorkers.perform(action, scope: registration.scope, tag: tag, in: web)
                switch action {
                case .sync: message = "Sync “\(tag?.isEmpty == false ? tag! : "test-tag-from-devtools")” registered."
                case .skipWaiting: message = "The waiting worker activated."
                default: break
                }
            } catch {
                message = error.localizedDescription
            }
        }
    }

}
