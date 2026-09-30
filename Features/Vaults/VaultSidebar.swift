import AzureARM
import SwiftUI

/// Sidebar: Favorites, Recent, All vaults (+ filter). Selection drives `ContextModel.selectedVaultID`.
struct VaultSidebar: View {
    @Environment(ContextModel.self) private var context

    var body: some View {
        @Bindable var context = context
        List(
            selection: Binding(
                get: { context.selectedVaultID },
                set: {
                    context.showsDeletedSecrets = false
                    context.selectVault($0)
                })
        ) {
            if let vault = context.selectedVault {
                Section(vault.name) {
                    Button {
                        context.showsDeletedSecrets = false
                    } label: {
                        Label("Secrets", systemImage: "key")
                    }
                    .buttonStyle(.plain).fontWeight(context.showsDeletedSecrets ? .regular : .semibold)
                    Button {
                        context.showsDeletedSecrets = true
                    } label: {
                        Label("Deleted secrets", systemImage: "trash")
                    }
                    .buttonStyle(.plain).fontWeight(context.showsDeletedSecrets ? .semibold : .regular)
                }
            }
            if !context.favoriteVaults.isEmpty {
                Section("Favorites") { rows(context.favoriteVaults) }
            }
            if !context.recentVaults.isEmpty {
                Section("Recent") { rows(context.recentVaults) }
            }
            Section("Vaults (\(context.vaults.count))") {
                switch context.vaultsPhase {
                case .loading: ProgressView().controlSize(.small)
                case .failed(let message):
                    if let error = context.vaultsError {
                        ErrorView(error: error, compact: true, onRetry: { context.reload() })
                    } else {
                        Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                    }
                case .idle:
                    if context.vaults.isEmpty {
                        Text(context.selectedSubscriptionID == nil ? "No subscription" : "No vaults")
                            .foregroundStyle(.secondary)
                    }
                    rows(context.filteredVaults)
                }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $context.vaultFilter, placement: .sidebar, prompt: "Filter vaults")
    }

    private func rows(_ vaults: [Vault]) -> some View {
        ForEach(vaults) { vault in
            VaultRow(vault: vault).tag(vault.id as String?)
        }
    }
}

struct VaultRow: View {
    @Environment(ContextModel.self) private var context
    let vault: Vault

    var body: some View {
        HStack(spacing: 6) {
            Text(vault.name).lineLimit(1)
            Spacer(minLength: 4)
            switch context.health[vault.id] {
            case .accessDenied: Text("🔒").help("Access denied")
            case .unreachable: Text("⚠️").help("Vault unreachable")
            case nil: EmptyView()
            }
            Text(vault.enableRbacAuthorization ? "RBAC" : "Policy")
                .font(.caption2).foregroundStyle(.secondary)
                .padding(.horizontal, 4)
                .background(.quaternary, in: Capsule())
                .help(vault.enableRbacAuthorization ? "Azure RBAC" : "Access policies")
        }
        .contextMenu {
            Button(
                context.isFavorite(vault) ? "Remove from Favorites" : "Add to Favorites",
                systemImage: context.isFavorite(vault) ? "star.slash" : "star"
            ) { context.toggleFavorite(vault) }
            Button("Open in Azure Portal", systemImage: "safari") {
                if let url = ContextModel.portalURL(for: vault, tenant: context.selectedTenantID) {
                    NSWorkspace.shared.open(url)
                }
            }
            Button("Copy Vault URI", systemImage: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(vault.vaultUri.absoluteString, forType: .string)
            }
        }
    }
}
