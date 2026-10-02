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
            let filtering = !context.vaultFilter.trimmingCharacters(in: .whitespaces).isEmpty
            if !filtering, let vault = context.selectedVault {
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
            if !filtering, !context.favoriteVaults.isEmpty {
                Section("Favorites") { rows(context.favoriteVaults) }
            }
            if !filtering, !context.recentVaults.isEmpty {
                Section("Recent") { rows(context.recentVaults) }
            }
            Section {
                switch context.vaultsPhase {
                case .loading:
                    if context.vaults.isEmpty { ProgressView().controlSize(.small) }
                case .failed(let message):
                    if let error = context.vaultsError {
                        ErrorView(error: error, compact: true, onRetry: { context.refreshVaults() })
                    } else {
                        Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                    }
                case .idle:
                    if context.vaults.isEmpty {
                        Text(context.selectedSubscriptionID == nil ? "No subscription" : "No vaults")
                            .foregroundStyle(.secondary)
                    } else if filtering && context.filteredVaults.isEmpty {
                        Text("No matching vaults").foregroundStyle(.secondary)
                    }
                }
                // One rows call for every phase so refresh/failure keep rows in place.
                rows(context.filteredVaults)
            } header: {
                HStack(spacing: 6) {
                    Text(
                        filtering
                            ? "Vaults (\(context.filteredVaults.count) of \(context.vaults.count))"
                            : "Vaults (\(context.vaults.count))")
                    if context.vaultsPhase == .loading && !context.vaults.isEmpty {
                        ProgressView().controlSize(.mini)
                    }
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
