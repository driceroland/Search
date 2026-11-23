import SwiftUI

/// Chromium's WebAuthn drawer tool: the virtual authenticator environment,
/// a form for new authenticators, and each authenticator with its
/// credentials (Export, Remove) and an Active choice.
struct DeveloperWebAuthnView: View {
    let session: DeveloperToolsSession
    @ObservedObject private var model: DeveloperWebAuthnModel
    @State private var draft = DeveloperVirtualAuthenticator(name: "")

    init(session: DeveloperToolsSession) {
        self.session = session
        _model = ObservedObject(wrappedValue: DeveloperWebAuthnModel.model(for: session))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Toggle("Enable virtual authenticator environment",
                       isOn: Binding(get: { model.enabled }, set: { model.setEnabled($0) }))
                    .toggleStyle(.developerCheckbox)
                    .accessibilityIdentifier("developer-webauthn-enable")
                Spacer()
            }
            .font(.system(size: 11))
            .padding(.horizontal, DeveloperToolsStyle.gutter)
            .frame(height: DeveloperToolsStyle.toolbarHeight)
            .background(DeveloperToolsStyle.chrome)
            Divider()
            if let problem = model.problem {
                Text(problem).foregroundStyle(.red).font(.system(size: 11)).padding(8)
            }
            if model.enabled {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        newAuthenticator
                        ForEach(model.authenticators) { authenticator in
                            Divider()
                            section(authenticator)
                        }
                        if !model.log.isEmpty {
                            Divider()
                            Text("Requests").font(.system(size: 11, weight: .semibold))
                            ForEach(Array(model.log.enumerated().reversed()), id: \.offset) { _, line in
                                Text(line).font(DeveloperToolsStyle.code).textSelection(.enabled)
                            }
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Text("Use WebAuthn for phishing-resistant authentication. Turn on the virtual authenticator environment to test it on this page: Search answers navigator.credentials.create() and get() with the authenticators you add here, instead of the system's.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .padding(16).frame(maxWidth: 520, alignment: .leading)
                Spacer()
            }
        }
        .accessibilityIdentifier("developer-webauthn")
    }

    private var newAuthenticator: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("New authenticator").font(.system(size: 11, weight: .semibold))
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 5) {
                GridRow {
                    Text("Protocol")
                    Picker("Protocol", selection: $draft.protocolKind) {
                        ForEach(DeveloperVirtualAuthenticator.ProtocolKind.allCases) { Text($0.rawValue).tag($0) }
                    }.labelsHidden().frame(width: 110)
                }
                GridRow {
                    Text("Transport")
                    Picker("Transport", selection: $draft.transport) {
                        ForEach(DeveloperVirtualAuthenticator.Transport.allCases) { Text($0.rawValue).tag($0) }
                    }.labelsHidden().frame(width: 110)
                }
                GridRow {
                    Text("Supports resident keys")
                    Toggle("", isOn: $draft.residentKeys).labelsHidden().disabled(draft.protocolKind == .u2f)
                }
                GridRow {
                    Text("Supports user verification")
                    Toggle("", isOn: $draft.userVerification).labelsHidden().disabled(draft.protocolKind == .u2f)
                }
            }
            Button("Add") { model.addAuthenticator(draft) }
                .accessibilityIdentifier("developer-webauthn-add")
        }
        .font(.system(size: 11))
    }

    private func section(_ authenticator: DeveloperVirtualAuthenticator) -> some View {
        let index = model.authenticators.firstIndex { $0.id == authenticator.id }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text(authenticator.name).font(.system(size: 12, weight: .semibold))
                Toggle("Active", isOn: Binding(get: { model.active == authenticator.id },
                                               set: { if $0 { model.active = authenticator.id } }))
                    .toggleStyle(.developerCheckbox)
                    .help("Only the active authenticator answers requests")
                Spacer()
                Button("Remove") { model.removeAuthenticator(authenticator.id) }
            }
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                row("UUID", authenticator.id.uuidString)
                row("Protocol", authenticator.protocolKind.rawValue)
                row("Transport", authenticator.transport.rawValue)
                row("Supports resident keys", authenticator.supportsResidentKeys ? "Yes" : "No")
                row("Supports user verification", authenticator.supportsUserVerification ? "Yes" : "No")
            }
            if authenticator.supportsUserVerification, let index {
                Toggle("Verify the user", isOn: $model.authenticators[index].userVerified).toggleStyle(.developerCheckbox)
            }
            Text("Credentials").font(.system(size: 11, weight: .semibold)).padding(.top, 4)
            if authenticator.credentials.isEmpty {
                Text("No credentials. Try calling navigator.credentials.create() from your website.")
                    .foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                    GridRow {
                        ForEach(["ID", "Is resident", "RP ID", "User handle", "Sign count", ""], id: \.self) {
                            Text($0).foregroundStyle(.secondary)
                        }
                    }
                    ForEach(authenticator.credentials) { credential in
                        GridRow {
                            Text(credential.idString).font(DeveloperToolsStyle.code).lineLimit(1).truncationMode(.middle)
                                .frame(maxWidth: 160, alignment: .leading).textSelection(.enabled)
                            Text(credential.isResident ? "true" : "false")
                            Text(credential.rpID)
                            Text(credential.userHandle.map(DeveloperWebAuthn.base64url) ?? "").font(DeveloperToolsStyle.code)
                                .lineLimit(1).truncationMode(.middle).frame(maxWidth: 120, alignment: .leading)
                            Text("\(credential.signCount)").monospacedDigit()
                            HStack(spacing: 6) {
                                Button("Export") { model.export(credential) }
                                Button("Remove") { model.removeCredential(credential.id, from: authenticator.id) }
                            }
                        }
                    }
                }
            }
        }
        .font(.system(size: 11))
    }

    private func row(_ name: String, _ value: String) -> some View {
        GridRow {
            Text(name).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }
}
