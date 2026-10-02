import AzureARM
import AzureCore
import Foundation
import KeyVaultSecrets

/// In-memory index of secret names per vault for the ⌘K palette. Never stores secret values.
public actor NameIndex {
    public enum InaccessibleReason: Sendable, Equatable {
        case unauthorized, forbidden, firewall, network
        case other(String)

        /// Short explanation shown next to a skipped vault.
        public var message: String {
            switch self {
            case .unauthorized: "Not signed in (401)"
            case .forbidden: "No permission (403)"
            case .firewall: "Blocked by vault firewall"
            case .network: "Unreachable (firewall or private endpoint)"
            case .other(let detail): "Error: \(detail)"
            }
        }
    }

    public enum VaultState: Sendable, Equatable {
        case pending, indexing
        case indexed(count: Int, at: Date)
        case inaccessible(InaccessibleReason)
    }

    public struct Progress: Sendable, Equatable {
        public var total: Int
        public var completed: Int
        public var inaccessible: Int
        public var secretCount: Int
        public var isFinished: Bool { completed >= total }
    }

    public struct Match: Sendable, Equatable, Identifiable {
        public let vault: Vault
        public let secretName: String
        public var id: String { vault.id + "/" + secretName }
    }

    /// Lists secret names of one vault (runs outside the actor).
    public typealias SecretNameLister = @Sendable (Vault) async throws -> [String]

    public static let defaultTTL: TimeInterval = 600
    public static let defaultConcurrency = 4

    private let lister: SecretNameLister
    private let ttl: TimeInterval
    private let concurrency: Int
    private let maxRetries: Int
    private let baseDelay: TimeInterval
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async throws -> Void

    private var tenant: String?
    private var vaults: [String: Vault] = [:]  // by vault id
    private var states: [String: VaultState] = [:]
    private var names: [String: [String]] = [:]
    private var generation = 0
    private var task: Task<Void, Never>?

    public init(
        ttl: TimeInterval = NameIndex.defaultTTL,
        concurrency: Int = NameIndex.defaultConcurrency,
        maxRetries: Int = 3,
        baseDelay: TimeInterval = 0.5,
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
        lister: @escaping SecretNameLister
    ) {
        self.ttl = ttl
        self.concurrency = max(1, concurrency)
        self.maxRetries = maxRetries
        self.baseDelay = baseDelay
        self.now = now
        self.sleep = sleep
        self.lister = lister
    }

    /// Lister backed by the Key Vault data plane using `tokenProvider` (one vault-audience token per tenant).
    public static func keyVaultLister(
        tokenProvider: any TokenProvider, tenant: String, transport: any HTTPTransport = URLSession.shared,
        retry: AzureHTTPClient.RetryPolicy = .init()
    ) -> SecretNameLister {
        { vault in
            let http = AzureHTTPClient(
                tokenProvider: tokenProvider, tenant: tenant, resource: .vault, transport: transport, retry: retry)
            let client = KeyVaultSecretsClient(vaultURI: vault.vaultUri, http: http)
            var out: [String] = []
            for try await page in client.listSecrets(maxResults: 25) { out += page.map(\.name) }
            return out
        }
    }

    // MARK: - Build

    /// Indexes `vaults` of `tenant`. Switching tenant drops the previous index and cancels a running build.
    /// Vaults indexed within the TTL are skipped unless `force`. Returns when finished (or cancelled).
    /// `onProgress` fires after each vault completes (and once up front).
    public func build(
        tenant: String, vaults newVaults: [Vault], force: Bool = false,
        onProgress: (@Sendable (Progress) -> Void)? = nil
    ) async {
        task?.cancel()
        if self.tenant != tenant { reset() }
        generation += 1
        let gen = generation
        self.tenant = tenant

        let ids = Set(newVaults.map(\.id))
        for id in vaults.keys where !ids.contains(id) {
            vaults[id] = nil
            states[id] = nil
            names[id] = nil
        }
        var todo: [Vault] = []
        for v in newVaults {
            vaults[v.id] = v
            if !force, case .indexed(_, let at)? = states[v.id], now().timeIntervalSince(at) < ttl { continue }
            states[v.id] = .pending
            todo.append(v)
        }
        onProgress?(progress)

        let lister = self.lister
        let limit = concurrency
        let work = Task { [weak self] in
            await withTaskGroup(of: (Vault, Result<[String], Error>).self) { group in
                var iterator = todo.makeIterator()
                func next() -> Bool {
                    guard !Task.isCancelled, let v = iterator.next() else { return false }
                    group.addTask { [weak self] in
                        guard let self else { return (v, .failure(CancellationError())) }
                        await self.mark(v, gen: gen)
                        return (v, await self.fetch(v, lister: lister))
                    }
                    return true
                }
                for _ in 0..<limit { if !next() { break } }  // swiftlint:disable:this for_where
                while let (v, result) = await group.next() {
                    await self?.record(v, result, gen: gen)
                    if let p = await self?.progressIfCurrent(gen) { onProgress?(p) }
                    _ = next()
                }
            }
        }
        task = work
        await work.value
    }

    /// Cancels a running build; indexed data is kept.
    public func cancel() {
        task?.cancel()
        generation += 1
    }

    /// Drops everything.
    public func reset() {
        task?.cancel()
        generation += 1
        tenant = nil
        vaults = [:]
        states = [:]
        names = [:]
    }

    private func mark(_ v: Vault, gen: Int) {
        if gen == generation { states[v.id] = .indexing }
    }

    private func progressIfCurrent(_ gen: Int) -> Progress? { gen == generation ? progress : nil }

    private func fetch(_ v: Vault, lister: SecretNameLister) async -> Result<[String], Error> {
        var attempt = 0
        while true {
            do { return .success(try await lister(v)) } catch {
                if error is CancellationError || Task.isCancelled { return .failure(error) }
                guard Self.isTransient(error), attempt < maxRetries else { return .failure(error) }
                let delay = min(baseDelay * pow(2, Double(attempt)), 30) * Double.random(in: 0.5...1)
                attempt += 1
                do { try await sleep(delay) } catch { return .failure(error) }
            }
        }
    }

    static func isTransient(_ error: Error) -> Bool {
        guard let e = error as? AzureAPIError else { return false }
        switch e {
        case .throttled: return true
        case .http(let status, _): return status >= 500
        default: return false
        }
    }

    private func record(_ v: Vault, _ result: Result<[String], Error>, gen: Int) {
        guard gen == generation else { return }
        switch result {
        case .success(let list):
            names[v.id] = list.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            states[v.id] = .indexed(count: list.count, at: now())
        case .failure(let error):
            if error is CancellationError {
                states[v.id] = .pending
                return
            }
            names[v.id] = nil
            states[v.id] = .inaccessible(Self.reason(error))
        }
    }

    static func reason(_ error: Error) -> InaccessibleReason {
        switch error as? AzureAPIError {
        case .unauthorized?: .unauthorized
        case .forbidden(let body)?: body?.isFirewallBlock == true ? .firewall : .forbidden
        case .network?: .network
        case let e?: .other(String(describing: e.statusCode ?? 0))
        case nil: .other(error.localizedDescription)
        }
    }

    // MARK: - Query

    public var progress: Progress {
        var p = Progress(total: vaults.count, completed: 0, inaccessible: 0, secretCount: 0)
        for s in states.values {
            switch s {
            case .indexed(let n, _):
                p.completed += 1
                p.secretCount += n
            case .inaccessible:
                p.completed += 1
                p.inaccessible += 1
            default: break
            }
        }
        return p
    }

    public func state(of vault: Vault) -> VaultState? { states[vault.id] }

    /// Vaults skipped because of 401/403/network errors (shown with 🔒).
    public var inaccessibleVaults: [(vault: Vault, reason: InaccessibleReason)] {
        states.compactMap { id, s in
            if case .inaccessible(let r) = s, let v = vaults[id] { return (v, r) }
            return nil
        }
        .sorted { $0.vault.name < $1.vault.name }
    }

    public func isInaccessible(_ vault: Vault) -> Bool {
        if case .inaccessible? = states[vault.id] { return true }
        return false
    }

    public func secretNames(in vault: Vault) -> [String] { names[vault.id] ?? [] }

    /// True when the vault has no fresh index (never indexed, or older than the TTL).
    public func isStale(_ vault: Vault) -> Bool {
        if case .indexed(_, let at)? = states[vault.id] { return now().timeIntervalSince(at) >= ttl }
        return true
    }

    /// Case-insensitive search: prefix matches first, then substring, then by vault/name. Empty query → none.
    public func search(_ query: String, limit: Int = 50, vault only: Vault? = nil) -> [Match] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }
        var scored: [(Int, Match)] = []
        for (id, list) in names {
            guard let v = vaults[id], only == nil || only?.id == id else { continue }
            for n in list {
                let l = n.lowercased()
                if l.hasPrefix(q) {
                    scored.append((0, Match(vault: v, secretName: n)))
                } else if l.contains(q) {
                    scored.append((1, Match(vault: v, secretName: n)))
                }
            }
        }
        scored.sort { a, b in
            if a.0 != b.0 { return a.0 < b.0 }
            if a.1.secretName != b.1.secretName { return a.1.secretName < b.1.secretName }
            return a.1.vault.name < b.1.vault.name
        }
        return scored.prefix(limit).map(\.1)
    }
}
