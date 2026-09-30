import AzureCLI
import SwiftUI

/// Login form + live progress (browser or device code with copy button). Shared by onboarding
/// and the Add account sheet.
struct LoginFlowView: View {
    @Environment(AppModel.self) private var model
    @State private var useDeviceCode = false
    @State private var tenant = ""
    @State private var displayName = ""
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let progress = model.loginProgress {
                progressView(progress)
            } else {
                form
            }
            if let error = model.loginError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Display name (optional)", text: $displayName)
            TextField("Tenant ID or domain (optional)", text: $tenant)
            Toggle("Use device code instead of the browser", isOn: $useDeviceCode)
            Button {
                model.addAccount(
                    displayName: displayName, useDeviceCode: useDeviceCode,
                    tenant: tenant.trimmingCharacters(in: .whitespaces).nilIfEmpty)
            } label: {
                Label("Sign in with Azure", systemImage: "person.badge.key")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
        .textFieldStyle(.roundedBorder)
    }

    @ViewBuilder
    private func progressView(_ progress: LoginProgress) -> some View {
        if let prompt = progress.deviceCode {
            VStack(alignment: .leading, spacing: 10) {
                Text("Open the page and enter this code:")
                HStack {
                    Text(prompt.code)
                        .font(.system(.title, design: .monospaced, weight: .semibold))
                        .textSelection(.enabled)
                    Button(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(prompt.code, forType: .string)
                        copied = true
                    }
                    Link("Open \(prompt.url.host() ?? "page")", destination: prompt.url)
                }
            }
        } else {
            HStack {
                ProgressView().controlSize(.small)
                Text(useDeviceCode ? "Waiting for device code…" : "Complete sign-in in your browser…")
            }
        }
        Button("Cancel", role: .cancel) { model.cancelLogin() }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
