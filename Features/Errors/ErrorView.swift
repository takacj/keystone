import AzureARM
import SwiftUI

/// Reusable error display with actions. Handles re-login / copy / portal itself; `onRetry` is the caller's.
///
/// Usage (#90): `ErrorView(error: err, vault: context.selectedVault, onRetry: { model.reload() })`.
/// It also flags the vault (🔒 / ⚠) in the sidebar via `ContextModel.markVault`.
struct ErrorView: View {
    @Environment(AppModel.self) private var app
    @Environment(ContextModel.self) private var context
    let error: Error
    var vault: Vault?
    var compact = false
    var onRetry: (() -> Void)?

    private var presentation: ErrorPresentation {
        ErrorPresentation.make(error, vault: vault, tenant: context.selectedTenantID)
    }

    var body: some View {
        let p = presentation
        Group {
            if compact {
                banner(p)
            } else {
                ContentUnavailableView {
                    Label(p.title, systemImage: p.symbol)
                } description: {
                    description(p)
                } actions: {
                    actionButtons(p)
                }
            }
        }
        .task(id: p) {
            if let vault, let health = p.vaultHealth { context.markVault(vault, health) }
        }
    }

    private func banner(_ p: ErrorPresentation) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(p.title, systemImage: p.symbol).font(.headline)
            description(p)
            HStack { actionButtons(p) }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    private func description(_ p: ErrorPresentation) -> some View {
        VStack(spacing: 4) {
            Text(p.message)
            if let detail = p.detail, !detail.isEmpty {
                Text(detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(4)
            }
        }
    }

    @ViewBuilder
    private func actionButtons(_ p: ErrorPresentation) -> some View {
        ForEach(p.actions, id: \.self) { action in
            switch action {
            case .retry:
                if let onRetry { Button("Retry", systemImage: "arrow.clockwise", action: onRetry) }
            case .reLogin(let tenant):
                if let account = app.selectedAccount {
                    Button("Sign in again", systemImage: "person.badge.key") {
                        app.reLogin(account, tenant: tenant)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(app.isLoggingIn)
                    .help("az login --tenant \(tenant ?? account.homeTenantId)")
                }
            case .copyRoleName(let role):
                Button("Copy “\(role)”", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(role, forType: .string)
                }
            case .openPortal:
                if let vault, let url = ContextModel.portalURL(for: vault, tenant: context.selectedTenantID) {
                    Button("Open in Portal", systemImage: "safari") { NSWorkspace.shared.open(url) }
                }
            }
        }
    }
}
