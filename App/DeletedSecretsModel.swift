import AzureARM
import AzureCore
import Foundation
import KeyVaultSecrets
import Observation

/// Operations the deleted-secrets UI needs (seam for tests).
struct DeletedSecretsOps: Sendable {
    var list: @Sendable () -> AsyncThrowingStream<[DeletedSecretItem], Error>
    var recover: @Sendable (String) async throws -> Void
    var purge: @Sendable (String) async throws -> Void

    init(
        list: @escaping @Sendable () -> AsyncThrowingStream<[DeletedSecretItem], Error>,
        recover: @escaping @Sendable (String) async throws -> Void,
        purge: @escaping @Sendable (String) async throws -> Void
    ) {
        self.list = list
        self.recover = recover
        self.purge = purge
    }

    init(client: KeyVaultSecretsClient) {
        self.init(
            list: { client.listDeletedSecrets(maxResults: 25) },
            recover: { _ = try await client.recoverDeletedSecret(name: $0) },
            purge: { try await client.purgeDeletedSecret(name: $0) }
        )
    }
}

/// One row of the deleted-secrets table.
struct DeletedSecretRow: Identifiable, Hashable, Sendable {
    let id: String  // secret name
    var name: String { id }
    let deletedDate: Date?
    let scheduledPurgeDate: Date?

    init(_ item: DeletedSecretItem) {
        id = item.name
        deletedDate = item.deletedDate
        scheduledPurgeDate = item.scheduledPurgeDate
    }

    init(name: String, deletedDate: Date? = nil, scheduledPurgeDate: Date? = nil) {
        id = name
        self.deletedDate = deletedDate
        self.scheduledPurgeDate = scheduledPurgeDate
    }
}

/// Per-item failure of a bulk recover/purge.
struct SecretOpFailure: Identifiable, Sendable {
    let name: String
    let error: Error
    var id: String { name }
    @MainActor var message: String { SecretsModel.message(for: error) }
}

/// Deleted (soft-deleted) secrets of the selected vault: list, recover, purge.
@MainActor @Observable
final class DeletedSecretsModel {
    enum Phase: Equatable { case idle, loading, loaded }

    private(set) var rows: [DeletedSecretRow] = []
    private(set) var phase: Phase = .idle
    private(set) var error: Error?
    private(set) var vault: Vault?
    private(set) var isWorking = false
    private(set) var failures: [SecretOpFailure] = []
    var selection: Set<String> = []

    var opsFactory: (Vault) -> DeletedSecretsOps?
    /// Called after names were recovered, so the secrets list can refresh.
    var onRecovered: () -> Void

    init(opsFactory: @escaping (Vault) -> DeletedSecretsOps? = { _ in nil }, onRecovered: @escaping () -> Void = {}) {
        self.opsFactory = opsFactory
        self.onRecovered = onRecovered
    }

    /// Purge is impossible while the vault has purge protection (secrets wait out retention).
    var purgeProtected: Bool { vault?.enablePurgeProtection ?? false }
    static let purgeProtectionExplanation =
        "Purge protection is enabled on this vault: deleted secrets can only be recovered, or wait for the retention period to end."

    func load(vault: Vault) async {
        if self.vault?.id != vault.id {
            self.vault = vault
            rows = []
            selection = []
            failures = []
        }
        self.vault = vault
        guard let ops = opsFactory(vault) else { return }
        phase = .loading
        error = nil
        var acc: [DeletedSecretRow] = []
        do {
            for try await page in ops.list() {
                acc += page.map(DeletedSecretRow.init)
                rows = Self.sorted(acc)
            }
            rows = Self.sorted(acc)
            selection = selection.intersection(Set(acc.map(\.id)))
            phase = .loaded
        } catch is CancellationError {
            return
        } catch {
            if Task.isCancelled { return }
            self.error = error
            phase = .loaded
        }
    }

    func refresh() async {
        guard let vault else { return }
        await load(vault: vault)
    }

    /// Recovers `names`; returns the recovered ones. Failures land in `failures`.
    @discardableResult
    func recover(_ names: [String]) async -> [String] {
        let done = await run(names) { $0.recover }
        if !done.isEmpty { onRecovered() }
        return done
    }

    /// Permanently purges `names` (refused up-front when purge-protected).
    @discardableResult
    func purge(_ names: [String]) async -> [String] {
        guard !purgeProtected else { return [] }
        return await run(names) { $0.purge }
    }

    /// Targets `vault` without loading (used by the 409 prompt from the secrets list).
    func attach(_ vault: Vault) {
        if self.vault?.id != vault.id {
            self.vault = vault
            rows = []
            selection = []
            failures = []
        }
    }

    /// Forces the next `load` to refetch (after deletes elsewhere); list is refetched when shown.
    func noteStale() { phase = .idle }

    private func run(
        _ names: [String],
        _ pick: (DeletedSecretsOps) -> @Sendable (String) async throws -> Void
    ) async -> [String] {
        guard let vault, let ops = opsFactory(vault), !names.isEmpty else { return [] }
        isWorking = true
        defer { isWorking = false }
        let op = pick(ops)
        let results = await KeyVaultSecretsClient.bulk(names, op)
        var ok: [String] = []
        var bad: [SecretOpFailure] = []
        for r in results {
            switch r.result {
            case .success: ok.append(r.input)
            case .failure(let e): bad.append(SecretOpFailure(name: r.input, error: e))
            }
        }
        failures = bad
        let okSet = Set(ok)
        rows.removeAll { okSet.contains($0.id) }
        selection.subtract(okSet)
        return ok
    }

    private static func sorted(_ rows: [DeletedSecretRow]) -> [DeletedSecretRow] {
        rows.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

extension DeletedSecretsModel {
    /// Test seam: injects rows and vault without network.
    func setForTesting(vault: Vault, rows: [DeletedSecretRow]) {
        self.vault = vault
        self.rows = rows
        phase = .loaded
    }
}

/// 409 handling: a secret with this name is deleted → offer recover / purge.
enum DeletedConflict {
    static func isConflict(_ error: Error) -> Bool {
        if case .conflict = error as? AzureAPIError { return true }
        return false
    }

    static func message(name: String, vault: Vault?) -> String {
        let base = "“\(name)” exists in Deleted secrets, so the name can't be reused yet. Recover it"
        if vault?.enablePurgeProtection == true {
            return base + " (purge is unavailable: purge protection is on)."
        }
        return base + " or purge it permanently to free the name."
    }
}
