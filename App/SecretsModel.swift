import AzureARM
import AzureCore
import Foundation
import KeyVaultSecrets
import Observation
import Search

/// One row of the secrets table (metadata only, never values).
struct SecretRow: Identifiable, Hashable, Sendable {
    let id: String  // secret name
    var name: String { id }
    let contentType: String
    let updated: Date?
    let expires: Date?
    let enabled: Bool
    let tags: [String: String]
    let tagsText: String
    // Non-optional sort keys for Table comparators.
    let updatedSort: Date
    let expiresSort: Date
    let enabledSort: Int

    init(_ item: SecretItem) {
        id = item.name
        contentType = item.contentType ?? ""
        updated = item.attributes?.updated ?? item.attributes?.created
        expires = item.attributes?.expires
        enabled = item.attributes?.enabled ?? true
        tags = item.tags ?? [:]
        tagsText = tags.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
        updatedSort = updated ?? .distantPast
        expiresSort = expires ?? .distantFuture
        enabledSort = enabled ? 1 : 0
    }
}

enum SecretChip: Hashable, CaseIterable {
    case enabled, disabled, expiring, expired

    var title: String {
        switch self {
        case .enabled: "Enabled"
        case .disabled: "Disabled"
        case .expiring: "Expiring ≤30d"
        case .expired: "Expired"
        }
    }
}

/// Secrets of the selected vault: streaming load (5 min TTL cache), fuzzy filter, chips, sort, selection.
@MainActor @Observable
final class SecretsModel {
    static let ttl: TimeInterval = 300
    static let expiringWindow: TimeInterval = 30 * 86400

    enum Phase: Equatable { case idle, loading, loaded }

    private(set) var rows: [SecretRow] = []
    private(set) var phase: Phase = .idle
    /// Last load failure (403 / network / …); the error UI presents it.
    private(set) var error: Error?
    private(set) var errorMessage: String?
    private(set) var vault: Vault?
    private(set) var loadedAt: Date?

    /// Filtered + sorted rows and per-row highlight ranges (UTF-16 offsets into the name).
    private(set) var visible: [SecretRow] = []
    private(set) var highlights: [String: [Range<Int>]] = [:]

    var filterText = "" { didSet { if filterText != oldValue { applyFilter() } } }
    private(set) var chips: Set<SecretChip> = []
    var tagFilter: String? { didSet { if tagFilter != oldValue { applyFilter() } } }
    var sortOrder: [KeyPathComparator<SecretRow>] = [] { didSet { applyFilter() } }
    var selection: Set<String> = []

    /// Builds the data-plane client for a vault (nil when no account / provider).
    var clientFactory: (Vault) -> KeyVaultSecretsClient?
    var onHealth: (Vault, VaultHealth?) -> Void
    private let now: () -> Date
    private var cache: [String: (rows: [SecretRow], at: Date)] = [:]

    init(
        clientFactory: @escaping (Vault) -> KeyVaultSecretsClient? = { _ in nil },
        onHealth: @escaping (Vault, VaultHealth?) -> Void = { _, _ in },
        now: @escaping () -> Date = Date.init
    ) {
        self.clientFactory = clientFactory
        self.onHealth = onHealth
        self.now = now
    }

    // MARK: Derived

    var disabledCount: Int { rows.lazy.filter { !$0.enabled }.count }

    /// All distinct `key=value` tags in the loaded rows.
    var availableTags: [String] {
        Set(rows.flatMap { $0.tags.map { "\($0.key)=\($0.value)" } }).sorted()
    }

    func selectedNames() -> [String] {
        visible.filter { selection.contains($0.id) }.map(\.name)
    }

    // MARK: Chips

    func toggle(_ chip: SecretChip) {
        if chips.contains(chip) {
            chips.remove(chip)
        } else {
            chips.insert(chip)
            if chip == .enabled { chips.remove(.disabled) }
            if chip == .disabled { chips.remove(.enabled) }
            if chip == .expired { chips.remove(.expiring) }
            if chip == .expiring { chips.remove(.expired) }
        }
        applyFilter()
    }

    func clearFilters() {
        chips = []
        tagFilter = nil
        filterText = ""
    }

    // MARK: Loading

    /// Loads secrets of `vault`, streaming pages into `rows`. Cached for 5 min unless `force`.
    func load(vault: Vault, force: Bool = false) async {
        if self.vault?.id != vault.id {
            self.vault = vault
            rows = []
            selection = []
            error = nil
            errorMessage = nil
            phase = .idle
            applyFilter()
        }
        if !force, let hit = cache[vault.id], now().timeIntervalSince(hit.at) < Self.ttl {
            rows = hit.rows
            loadedAt = hit.at
            phase = .loaded
            applyFilter()
            return
        }
        guard let client = clientFactory(vault) else { return }
        phase = .loading
        error = nil
        errorMessage = nil
        var acc: [SecretRow] = []
        var first = true
        do {
            for try await page in client.listSecrets(maxResults: 25) {
                acc += page.map(SecretRow.init)
                rows = acc
                if first {
                    first = false
                    selection = selection.intersection(Set(acc.map(\.id)))
                }
                applyFilter()
            }
            if first { rows = [] }  // empty vault
            cache[vault.id] = (acc, now())
            loadedAt = now()
            phase = .loaded
            applyFilter()
            onHealth(vault, nil)
        } catch is CancellationError {
            return
        } catch {
            if Task.isCancelled { return }
            let api = error as? AzureAPIError
            self.error = error
            errorMessage = Self.message(for: error)
            phase = .loaded
            switch api {
            case .forbidden: onHealth(vault, .accessDenied)
            case .network: onHealth(vault, .unreachable)
            default: break
            }
        }
    }

    /// Fire-and-forget refresh (for retry buttons).
    func reload() { Task { await refresh() } }

    func refresh() async {
        guard let vault else { return }
        await load(vault: vault, force: true)
    }

    func invalidateCache() { cache = [:] }

    /// Soft-deletes `names` (bulk, 4 concurrent). Removes deleted rows locally; returns per-item failures.
    /// `perform` overrides the data-plane call (tests).
    @discardableResult
    func delete(
        names: [String],
        perform: (@Sendable (Vault, String) async throws -> Void)? = nil
    ) async -> [SecretOpFailure] {
        guard let vault, !names.isEmpty else { return [] }
        let op: @Sendable (String) async throws -> Void
        if let perform {
            op = { try await perform(vault, $0) }
        } else {
            guard let client = clientFactory(vault) else { return [] }
            op = { _ = try await client.deleteSecret(name: $0) }
        }
        let results = await KeyVaultSecretsClient.bulk(names, op)
        var done: Set<String> = []
        var failed: [SecretOpFailure] = []
        for r in results {
            switch r.result {
            case .success: done.insert(r.input)
            case .failure(let e): failed.append(SecretOpFailure(name: r.input, error: e))
            }
        }
        rows.removeAll { done.contains($0.id) }
        selection.subtract(done)
        cache[vault.id] = (rows, now())
        applyFilter()
        return failed
    }

    static func message(for error: Error) -> String {
        switch error as? AzureAPIError {
        case .forbidden: "Access denied — you lack permission to list secrets in this vault."
        case .unauthorized: "Not signed in for this tenant. Re-login and retry."
        case .network(let code): "Network error (\(code.rawValue)). The vault may be unreachable or firewalled."
        case .throttled: "Throttled by Key Vault. Try again shortly."
        case .http(let status, let body): "Key Vault error \(status)\(body?.message.map { ": \($0)" } ?? "")"
        case .notFound: "Vault not found."
        default: error.localizedDescription
        }
    }

    // MARK: Filtering

    func applyFilter() {
        let n = now()
        let horizon = n.addingTimeInterval(Self.expiringWindow)
        var base = rows.filter { row in
            for chip in chips {
                switch chip {
                case .enabled: if !row.enabled { return false }
                case .disabled: if row.enabled { return false }
                case .expiring: guard let e = row.expires, e >= n, e <= horizon else { return false }
                case .expired: guard let e = row.expires, e < n else { return false }
                }
            }
            if let tag = tagFilter, !row.tags.contains(where: { "\($0.key)=\($0.value)" == tag }) { return false }
            return true
        }
        if !sortOrder.isEmpty { base.sort(using: sortOrder) }
        let matcher = FuzzyMatcher(query: filterText)
        if matcher.isEmpty {
            visible =
                sortOrder.isEmpty
                ? base.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } : base
            highlights = [:]
            return
        }
        // With an explicit sort keep it; otherwise rank by relevance.
        let hits = matcher.filter(base) { $0.name }
        var h: [String: [Range<Int>]] = [:]
        for hit in hits { h[hit.item.id] = hit.match.ranges }
        highlights = h
        if sortOrder.isEmpty {
            visible = hits.map(\.item)
        } else {
            let ids = Set(hits.map(\.item.id))
            visible = base.filter { ids.contains($0.id) }
        }
    }
}

extension SecretsModel {
    /// Test seam: injects rows without network.
    func setRowsForTesting(_ new: [SecretRow]) {
        rows = new
        applyFilter()
    }
}
