import AzureCLI
import SwiftUI

/// First-run experience: detect `az`, then sign in the first account.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "key.viewfinder").font(.system(size: 48)).foregroundStyle(.tint)
            Text("Welcome to Keystone").font(.largeTitle.bold())
            switch model.azureStatus {
            case .checking:
                ProgressView()
            case .missing:
                MissingAzureView()
            case .ready(let version):
                if let version, model.azureStatus.isOutdated {
                    Label(
                        "Azure CLI \(version) is older than \(AzureVersion.minimumSupported.description). Run `brew upgrade azure-cli`.",
                        systemImage: "exclamationmark.triangle"
                    ).foregroundStyle(.orange)
                } else if let version {
                    Text("Azure CLI \(version.description) found").font(.caption).foregroundStyle(.secondary)
                }
                Text("Sign in to an Azure account to browse Key Vault secrets.").foregroundStyle(.secondary)
                LoginFlowView().frame(maxWidth: 360)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .glassEffect(.regular, in: .rect(cornerRadius: 0))
    }
}

struct MissingAzureView: View {
    @Environment(AppModel.self) private var model
    static let command = "brew install azure-cli"

    var body: some View {
        VStack(spacing: 12) {
            Label("Azure CLI (az) was not found", systemImage: "exclamationmark.triangle.fill")
                .font(.headline).foregroundStyle(.orange)
            Text("Install it with Homebrew, then check again:")
            HStack {
                Text(Self.command)
                    .font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    .padding(8).background(.quaternary, in: .rect(cornerRadius: 8))
                Button("Copy", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(Self.command, forType: .string)
                }
            }
            Button("Check again") { Task { await model.bootstrap() } }
                .buttonStyle(.borderedProminent)
        }
    }
}
