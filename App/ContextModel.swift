import AzureARM
import AzureAuth
import Foundation
import Observation
import Persistence

/// Per-vault problem flagged by later features (secrets list); drives sidebar badges.
enum VaultHealth: Equatable {
    case accessDenied  // 🔒
    case unreachable  // ⚠
}

/// Tenant → subscription → vault selection for the current account.
///
/// Every switch cancels the in-flight load of the previous context. Selection, favorites and recents
/// are persisted per account in `ContextStateStore`.
@MainActor @Observable
final class ContextModel {
    enum Phase: Equatable {
        case idle, loading
        case failed(String)
    }

    // MARK: State
    private(set) var account: AccountProfile?
    private(set) var tenants: [Tenant] = []
    private(set) var subscriptions: [Subscription] = []
    private(set) var vaults: [Vault] = []
    private(set) var selectedTenantID: String?
    private(set) var selectedSubscriptionID: String?
    private(set) var selectedVaultID: String?
    private(set) var tenantsPhase: Phase = .idle
    private(set) var subscriptionsPhase: Phase = .idle
    private(set) var vaultsPhase: Phase = .idle
    private(set) var favoriteIDs: [String] = []
    private(set) var recentIDs: [String] = []
    private(set) var health: [String: VaultHealth] = [:]
    /// Underlying errors of the last failed load (for `ErrorView`); cleared when the load restarts.
    private(set) var tenantsError: Error?
    private(set) var subscriptionsError: Error?
    private(set) var vaultsError: Error?
    /// Sidebar "All" filter text.
    var vaultFilter = ""

    /// Bumped on every vault switch.
    private(set) var contextGeneration = 0

    var selectedSubscription: Subscription? { subscriptions.first { $0.subscriptionId == selectedSubscriptionID } }
    /// Content column shows “Deleted secrets” of the selected vault instead of the secrets list.
    var showsDeletedSecrets = false

    var selectedVault: Vault? { vaults.first { $0.id.lowercased() == selectedVaultID?.lowercased() } }

    var favoriteVaults: [Vault] { favoriteIDs.compactMap(vault(withID:)) }
    var recentVaults: [Vault] { recentIDs.compactMap(vault(withID:)) }
    var filteredVaults: [Vault] {
        let all = vaults.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let q = vaultFilter.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? all : all.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    // MARK: Dependencies
    private var client: ARMClient?
    private let store: ContextStateStore
    private var state = AccountContextState()
    private var tenantTask: Task<Void, Never>?
    private var subscriptionTask: Task<Void, Never>?
    private var vaultTask: Task<Void, Never>?

    init(store: ContextStateStore = ContextStateStore()) {
        self.store = store
    }

    // MARK: Switching

    /// Switches to `account` (or clears with nil): cancels loads, restores persisted selection, reloads tenants.
    func switchAccount(_ account: AccountProfile?, client: ARMClient?) {
        cancelAll()
        self.account = account
        self.client = client
        tenants = []
        subscriptions = []
        vaults = []
        selectedTenantID = nil
        selectedSubscriptionID = nil
        selectedVaultID = nil
        health = [:]
        tenantsError = nil
        subscriptionsError = nil
        vaultsError = nil
        vaultFilter = ""
        tenantsPhase = .idle
        subscriptionsPhase = .idle
        vaultsPhase = .idle
        guard let account else {
            state = AccountContextState()
            favoriteIDs = []
            recentIDs = []
            return
        }
        state = store.load(accountID: account.id)
        favoriteIDs = state.favorites
        recentIDs = state.recents
        loadTenants()
    }

    /// Re-fetches everything for the current account, keeping the current selection where possible.
    func reload() {
        guard let account else { return }
        state.tenantId = selectedTenantID ?? state.tenantId
        state.subscriptionId = selectedSubscriptionID ?? state.subscriptionId
        state.vaultId = selectedVaultID ?? state.vaultId
        switchAccount(account, client: client)
    }

    func selectTenant(_ id: String) {
        guard id != selectedTenantID else { return }
        cancelSubscriptionsAndBelow()
        selectedTenantID = id
        state.tenantId = id
        state.subscriptionId = nil
        state.vaultId = nil
        persist()
        loadSubscriptions()
    }

    func selectSubscription(_ id: String) {
        guard id != selectedSubscriptionID else { return }
        cancelVaults()
        selectedSubscriptionID = id
        state.subscriptionId = id
        state.vaultId = nil
        persist()
        loadVaults()
    }

    func selectVault(_ id: String?) {
        guard id != selectedVaultID else { return }
        selectedVaultID = id
        contextGeneration += 1
        state.vaultId = id
        if let id {
            recentIDs.removeAll { $0.lowercased() == id.lowercased() }
            recentIDs.insert(id, at: 0)
            recentIDs = Array(recentIDs.prefix(ContextStateStore.maxRecents))
            state.recents = recentIDs
        }
        persist()
    }

    // MARK: Favorites / health

    func isFavorite(_ vault: Vault) -> Bool {
        favoriteIDs.contains { $0.lowercased() == vault.id.lowercased() }
    }

    func toggleFavorite(_ vault: Vault) {
        if isFavorite(vault) {
            favoriteIDs.removeAll { $0.lowercased() == vault.id.lowercased() }
        } else {
            favoriteIDs.append(vault.id)
        }
        state.favorites = favoriteIDs
        persist()
    }

    func markVault(_ vault: Vault, _ value: VaultHealth?) {
        health[vault.id] = value
    }

    // MARK: Loading

    private func loadTenants() {
        guard let account, let client else { return }
        tenantsPhase = .loading
        tenantsError = nil
        let home = account.homeTenantId
        tenantTask = Task { [weak self] in
            do {
                let result = try await client.tenants(homeTenant: home)
                try Task.checkCancellation()
                self?.tenantsLoaded(result, home: home)
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled { self?.tenantsFailed(error) }
            }
        }
    }

    private func tenantsFailed(_ error: Error) {
        tenantsError = error
        tenantsPhase = .failed(error.localizedDescription)
    }

    private func subscriptionsFailed(_ error: Error) {
        subscriptionsError = error
        subscriptionsPhase = .failed(error.localizedDescription)
    }

    private func vaultsFailed(_ error: Error) {
        vaultsError = error
        vaultsPhase = .failed(error.localizedDescription)
    }

    private func tenantsLoaded(_ result: [Tenant], home: String) {
        tenants = result
        tenantsPhase = .idle
        let pick =
            [state.tenantId, home].lazy.compactMap { $0 }
            .first { id in result.contains { $0.tenantId == id } }
            ?? result.first?.tenantId
        selectedTenantID = pick
        state.tenantId = pick
        if pick != nil { loadSubscriptions() }
    }

    private func loadSubscriptions() {
        guard let client, let tenant = selectedTenantID else { return }
        subscriptions = []
        vaults = []
        selectedSubscriptionID = nil
        selectedVaultID = nil
        subscriptionsPhase = .loading
        subscriptionsError = nil
        subscriptionTask = Task { [weak self] in
            do {
                let result = try await client.subscriptions(tenant: tenant)
                try Task.checkCancellation()
                self?.subscriptionsLoaded(result)
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled { self?.subscriptionsFailed(error) }
            }
        }
    }

    private func subscriptionsLoaded(_ result: [Subscription]) {
        subscriptions = result
        subscriptionsPhase = .idle
        let enabled = result.filter { ($0.state ?? "Enabled").lowercased() == "enabled" }
        let pick =
            result.first { $0.subscriptionId == state.subscriptionId }?.subscriptionId
            ?? enabled.first?.subscriptionId ?? result.first?.subscriptionId
        selectedSubscriptionID = pick
        state.subscriptionId = pick
        if pick != nil { loadVaults() }
    }

    private func loadVaults() {
        guard let client, let tenant = selectedTenantID, let sub = selectedSubscriptionID else { return }
        vaults = []
        selectedVaultID = nil
        vaultsPhase = .loading
        vaultsError = nil
        vaultTask = Task { [weak self] in
            do {
                let result = try await client.vaults(subscriptionId: sub, tenant: tenant)
                try Task.checkCancellation()
                self?.vaultsLoaded(result)
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled { self?.vaultsFailed(error) }
            }
        }
    }

    private func vaultsLoaded(_ result: [Vault]) {
        vaults = result
        vaultsPhase = .idle
        let saved = state.vaultId?.lowercased()
        let restored = result.first { $0.id.lowercased() == saved }
        selectedVaultID = restored?.id
        contextGeneration += 1
    }

    // MARK: Cancellation

    private func cancelVaults() {
        vaultTask?.cancel()
        vaultTask = nil
        vaultsPhase = .idle
    }

    private func cancelSubscriptionsAndBelow() {
        subscriptionTask?.cancel()
        subscriptionTask = nil
        subscriptionsPhase = .idle
        cancelVaults()
    }

    private func cancelAll() {
        tenantTask?.cancel()
        tenantTask = nil
        cancelSubscriptionsAndBelow()
    }

    // MARK: Helpers

    private func vault(withID id: String) -> Vault? {
        vaults.first { $0.id.lowercased() == id.lowercased() }
    }

    private func persist() {
        guard let account else { return }
        store.save(state, accountID: account.id)
    }

    /// Azure Portal deep link for a vault.
    static func portalURL(for vault: Vault, tenant: String?) -> URL? {
        let base = "https://portal.azure.com/"
        let tenantPart = tenant.map { "#@\($0)" } ?? "#"
        return URL(string: "\(base)\(tenantPart)/resource\(vault.id)/overview")
    }
}
