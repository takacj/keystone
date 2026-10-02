import AppKit
import AzureARM
import AzureCore
import Foundation
import KeyVaultSecrets
import Observation
import Search

/// "Search by value" sheet (⇧⌘F): reads every secret value of the chosen vaults and lists the secrets whose value
/// matches. The query and the values stay in memory only; everything is dropped on close and on app lock.
@MainActor @Observable
final class ValueSearchModel {
    enum Scope: String, CaseIterable, Identifiable {
        case currentVault = "Current vault"
        case currentSubscription = "Subscription"
        case allInTenant = "All in tenant"
        var id: String { rawValue }
    }

    enum Phase: Equatable {
        case idle, scanning, finished, cancelled
        case failed(String)
    }

    struct Skipped: Identifiable, Equatable {
        let vault: Vault
        let reason: NameIndex.InaccessibleReason
        var id: String { vault.id }
    }

    var isPresented = false
    var value = ""
    var isRevealed = false
    var scope: Scope = .currentVault
    var mode: ValueSearcher.MatchMode = .exact
    var caseSensitive = true
    var includeDisabled = false
    private(set) var phase: Phase = .idle
    private(set) var progress: ValueSearcher.Progress?
    private(set) var matches: [ValueSearcher.Match] = []
    private(set) var skipped: [Skipped] = []
    /// Production vaults in scope awaiting confirmation; the scan starts on `confirmProduction()`.
    private(set) var pendingProduction: [Vault]?
    private(set) var toast: String?

    // Dependencies (wired by MainView; replaced by fakes in tests).
    var currentVault: () -> Vault? = { nil }
    var subscriptionVaults: () -> [Vault] = { [] }
    var tenantVaults: () async throws -> [Vault] = { [] }
    var subscriptionName: (String) -> String? = { _ in nil }
    var prodGuard: () -> ProdGuard = { ProdGuard.current() }
    var makeSearcher: () -> ValueSearcher? = { nil }
    var writePlain: (String) -> Void = { text in
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }
    var navigate: (Vault, String?) async -> Void = { _, _ in }

    private(set) var scanTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?
    private var pendingVaults: [Vault] = []
    private var generation = 0

    var isScanning: Bool { phase == .scanning }
    var canStart: Bool { !value.isEmpty && !isScanning }

    // MARK: Presentation

    func open() {
        clear()
        isPresented = true
    }

    /// Closes the sheet and forgets the query and the results.
    func close() {
        isPresented = false
        clear()
    }

    /// App lock: cancel the scan, drop query and results.
    func lockChanged() { close() }

    private func clear() {
        cancelScan()
        value = ""
        isRevealed = false
        phase = .idle
        progress = nil
        matches = []
        skipped = []
        pendingProduction = nil
        pendingVaults = []
    }

    // MARK: Scan

    /// Resolves the scope and starts scanning, or asks for confirmation first when it includes production vaults.
    func start() async {
        guard canStart else { return }
        let gen = generation
        let vaults: [Vault]
        do { vaults = try await resolveVaults() } catch {
            guard gen == generation else { return }
            phase = .failed(error.localizedDescription)
            return
        }
        guard gen == generation else { return }
        guard !vaults.isEmpty else {
            phase = .failed(scope == .currentVault ? "Select a vault first." : "No vaults in scope.")
            return
        }
        let guardrail = prodGuard()
        let prod = vaults.filter {
            guardrail.isProduction(subscriptionName: subscriptionName($0.subscriptionId), vaultName: $0.name)
        }
        if prod.isEmpty {
            begin(vaults)
        } else {
            pendingVaults = vaults
            pendingProduction = prod
        }
    }

    func confirmProduction() {
        guard pendingProduction != nil else { return }
        let vaults = pendingVaults
        pendingProduction = nil
        pendingVaults = []
        begin(vaults)
    }

    func cancelProduction() {
        pendingProduction = nil
        pendingVaults = []
    }

    func cancelScan() {
        generation += 1
        scanTask?.cancel()
        scanTask = nil
        if phase == .scanning { phase = .cancelled }
    }

    private func resolveVaults() async throws -> [Vault] {
        let vaults: [Vault]
        switch scope {
        case .currentVault: vaults = currentVault().map { [$0] } ?? []
        case .currentSubscription: vaults = subscriptionVaults()
        case .allInTenant: vaults = try await tenantVaults()
        }
        return vaults.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func begin(_ vaults: [Vault]) {
        guard let searcher = makeSearcher() else {
            phase = .failed("Not signed in.")
            return
        }
        cancelScan()
        let gen = generation
        matches = []
        skipped = []
        progress = nil
        phase = .scanning
        let query = ValueSearcher.Query(
            value: value, mode: mode, caseSensitive: caseSensitive, includeDisabled: includeDisabled)
        let stream = searcher.search(query, in: vaults)
        scanTask = Task { [weak self] in
            for await event in stream {
                guard let self, gen == self.generation else { return }
                switch event {
                case .progress(let p): self.progress = p
                case .match(let m): self.matches.append(m)
                case .skipped(let v, let r): self.skipped.append(Skipped(vault: v, reason: r))
                }
            }
            guard let self, gen == self.generation else { return }
            self.phase = Task.isCancelled ? .cancelled : .finished
        }
    }

    // MARK: Results

    /// Closes the sheet and selects the secret in the main window (like the palette's ↩).
    func openMatch(_ match: ValueSearcher.Match) async {
        close()
        await navigate(match.vault, match.secretName)
    }

    func copyName(_ match: ValueSearcher.Match) {
        writePlain(match.secretName)
        showToast("Copied \(match.secretName)")
    }

    private func showToast(_ text: String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { self?.toast = nil }
        }
    }
}

extension ValueSearchModel {
    /// Searcher over the Key Vault data plane that reads through (and fills) `cache`.
    nonisolated static func liveSearcher(
        client: @escaping @Sendable (Vault) -> KeyVaultSecretsClient?, cache: SecretValueCache = .shared
    ) -> ValueSearcher {
        ValueSearcher(
            lister: ValueSearcher.keyVaultLister(client: client),
            fetcher: { vault, name in
                let key = SecretValueCache.Key(vault: vault.vaultUri.absoluteString, name: name)
                if let hit = cache.get(key) { return hit.value }
                guard let c = client(vault) else { throw AzureAPIError.unauthorized(nil) }
                let bundle = try await c.getSecret(name: name)
                cache.set(key, bundle)
                return bundle.value
            })
    }
}
