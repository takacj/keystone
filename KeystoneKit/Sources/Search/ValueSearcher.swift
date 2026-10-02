import AzureARM
import AzureCore
import Foundation
import KeyVaultSecrets

/// Finds secrets whose current value matches a query by fetching every value (Key Vault has no server-side
/// value search). Values are compared and dropped; they are never stored, indexed or logged here.
public struct ValueSearcher: Sendable {
    public enum MatchMode: Sendable, Equatable { case exact, contains }

    public struct Query: Sendable {
        public var value: String
        public var mode: MatchMode
        public var caseSensitive: Bool
        public var includeDisabled: Bool

        public init(value: String, mode: MatchMode = .exact, caseSensitive: Bool = true, includeDisabled: Bool = false)
        {
            self.value = value
            self.mode = mode
            self.caseSensitive = caseSensitive
            self.includeDisabled = includeDisabled
        }
    }

    /// Secret metadata from the vault listing (no value).
    public struct Candidate: Sendable, Equatable {
        public let name: String
        public let enabled: Bool
        public let expires: Date?

        public init(name: String, enabled: Bool = true, expires: Date? = nil) {
            self.name = name
            self.enabled = enabled
            self.expires = expires
        }
    }

    public struct Match: Sendable, Equatable, Identifiable {
        public let vault: Vault
        public let secretName: String
        public let enabled: Bool
        public let expires: Date?
        public var id: String { vault.id + "/" + secretName }
    }

    public struct Progress: Sendable, Equatable {
        public var vaultsTotal = 0
        public var vaultsScanned = 0
        /// Secrets to read in the vaults listed so far.
        public var secretsTotal = 0
        public var secretsScanned = 0
        /// Secrets whose value couldn't be read (skipped).
        public var secretsFailed = 0
        public var matches = 0

        public init(vaultsTotal: Int = 0) { self.vaultsTotal = vaultsTotal }
    }

    public enum Event: Sendable, Equatable {
        case progress(Progress)
        case match(Match)
        case skipped(Vault, NameIndex.InaccessibleReason)
    }

    /// Lists secret metadata of one vault.
    public typealias SecretLister = @Sendable (Vault) async throws -> [Candidate]
    /// Fetches the current value of one secret (nil = no value).
    public typealias ValueFetcher = @Sendable (Vault, String) async throws -> String?

    private let lister: SecretLister
    private let fetcher: ValueFetcher
    private let concurrency: Int
    private let maxRetries: Int
    private let baseDelay: TimeInterval
    private let sleep: @Sendable (TimeInterval) async throws -> Void

    /// Secrets fetched per `KeyVaultSecretsClient.bulk` call; progress/matches are reported after each chunk.
    static let chunkSize = 20

    public init(
        concurrency: Int = keyVaultBulkConcurrency,
        maxRetries: Int = 3,
        baseDelay: TimeInterval = 0.5,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
        lister: @escaping SecretLister,
        fetcher: @escaping ValueFetcher
    ) {
        self.concurrency = max(1, concurrency)
        self.maxRetries = maxRetries
        self.baseDelay = baseDelay
        self.sleep = sleep
        self.lister = lister
        self.fetcher = fetcher
    }

    /// Lister backed by the Key Vault data plane.
    public static func keyVaultLister(client: @escaping @Sendable (Vault) -> KeyVaultSecretsClient?) -> SecretLister {
        { vault in
            guard let c = client(vault) else { throw AzureAPIError.unauthorized(nil) }
            var out: [Candidate] = []
            for try await page in c.listSecrets() {
                out += page.map {
                    Candidate(name: $0.name, enabled: $0.attributes?.enabled ?? true, expires: $0.attributes?.expires)
                }
            }
            return out
        }
    }

    /// Scans `vaults` one after another (secrets of a vault with bounded concurrency). Cancelling the consuming
    /// task (or dropping the stream) stops the scan. The stream finishes after the last vault.
    public func search(_ query: Query, in vaults: [Vault]) -> AsyncStream<Event> {
        AsyncStream { continuation in
            let task = Task {
                await run(query, vaults, continuation)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(_ query: Query, _ vaults: [Vault], _ out: AsyncStream<Event>.Continuation) async {
        let matcher = Matcher(query)
        guard matcher.isValid else { return }
        var progress = Progress(vaultsTotal: vaults.count)
        out.yield(.progress(progress))
        for vault in vaults {
            if Task.isCancelled { return }
            let candidates: [Candidate]
            switch await retrying({ try await lister(vault) }) {
            case .success(let list): candidates = list.filter { query.includeDisabled || $0.enabled }
            case .failure(let error):
                if Task.isCancelled { return }
                out.yield(.skipped(vault, NameIndex.reason(error)))
                progress.vaultsScanned += 1
                out.yield(.progress(progress))
                continue
            }
            progress.secretsTotal += candidates.count
            out.yield(.progress(progress))
            if let reason = await scan(vault, candidates, matcher, &progress, out) {
                out.yield(.skipped(vault, reason))
            }
            if Task.isCancelled { return }
            progress.vaultsScanned += 1
            out.yield(.progress(progress))
        }
    }

    /// Returns a reason when the vault turned out to be unreadable (first chunk all 401/403).
    private func scan(
        _ vault: Vault, _ candidates: [Candidate], _ matcher: Matcher, _ progress: inout Progress,
        _ out: AsyncStream<Event>.Continuation
    ) async -> NameIndex.InaccessibleReason? {
        var start = 0
        while start < candidates.count {
            if Task.isCancelled { return nil }
            let chunk = Array(candidates[start..<min(start + Self.chunkSize, candidates.count)])
            let results = await KeyVaultSecretsClient.bulk(chunk, limit: concurrency) { [self] c in
                try await retrying { try await fetcher(vault, c.name) }.get()
            }
            if Task.isCancelled { return nil }
            if start == 0, let reason = Self.deniedReason(results.map(\.result)) {
                progress.secretsTotal -= candidates.count
                return reason
            }
            for (c, result) in results {
                progress.secretsScanned += 1
                switch result {
                case .success(let value):
                    guard let value, matcher.matches(value) else { continue }
                    progress.matches += 1
                    out.yield(.match(Match(vault: vault, secretName: c.name, enabled: c.enabled, expires: c.expires)))
                case .failure: progress.secretsFailed += 1
                }
            }
            out.yield(.progress(progress))
            start += chunk.count
        }
        return nil
    }

    /// Every read denied → the identity can list but not get (vault-wide), so skip the rest of the vault.
    private static func deniedReason(_ results: [Result<String?, Error>]) -> NameIndex.InaccessibleReason? {
        guard !results.isEmpty else { return nil }
        var reason: NameIndex.InaccessibleReason?
        for r in results {
            guard case .failure(let error) = r else { return nil }
            switch error as? AzureAPIError {
            case .unauthorized?, .forbidden?: reason = NameIndex.reason(error)
            default: return nil
            }
        }
        return reason
    }

    private func retrying<T: Sendable>(_ op: () async throws -> T) async -> Result<T, Error> {
        var attempt = 0
        while true {
            do { return .success(try await op()) } catch {
                if error is CancellationError || Task.isCancelled { return .failure(error) }
                guard NameIndex.isTransient(error), attempt < maxRetries else { return .failure(error) }
                let delay = min(baseDelay * pow(2, Double(attempt)), 30) * Double.random(in: 0.5...1)
                attempt += 1
                do { try await sleep(delay) } catch { return .failure(error) }
            }
        }
    }

    // MARK: Matching

    struct Matcher: Sendable {
        let query: Query
        private let needle: [UInt8]

        init(_ query: Query) {
            self.query = query
            needle = Array((query.caseSensitive ? query.value : query.value.lowercased()).utf8)
        }

        var isValid: Bool { !needle.isEmpty }

        func matches(_ value: String) -> Bool {
            switch query.mode {
            case .exact:
                Self.constantTimeEquals(needle, Array((query.caseSensitive ? value : value.lowercased()).utf8))
            case .contains:
                value.range(of: query.value, options: query.caseSensitive ? [] : .caseInsensitive) != nil
            }
        }

        /// Time depends only on the longer length, not on where the inputs first differ.
        static func constantTimeEquals(_ a: [UInt8], _ b: [UInt8]) -> Bool {
            var diff: UInt8 = a.count == b.count ? 0 : 1
            for i in 0..<max(a.count, b.count) {
                diff |= (i < a.count ? a[i] : 0) ^ (i < b.count ? b[i] : 0)
            }
            return diff == 0
        }
    }
}
