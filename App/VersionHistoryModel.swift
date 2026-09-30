import AzureARM
import Foundation
import KeyVaultSecrets
import Observation

/// Operations the version history needs (seam for tests).
struct VersionHistoryOps: Sendable {
    var list: @Sendable (String) async throws -> [SecretItem]
    var get: @Sendable (String, String?) async throws -> SecretBundle
    var set: @Sendable (String, SetSecretRequest) async throws -> SecretBundle

    init(
        list: @escaping @Sendable (String) async throws -> [SecretItem],
        get: @escaping @Sendable (String, String?) async throws -> SecretBundle,
        set: @escaping @Sendable (String, SetSecretRequest) async throws -> SecretBundle
    ) {
        self.list = list
        self.get = get
        self.set = set
    }

    init(client: KeyVaultSecretsClient) {
        self.init(
            list: { name in
                var all: [SecretItem] = []
                for try await page in client.listVersions(name: name, maxResults: 25) { all += page }
                return all
            },
            get: { try await client.getSecret(name: $0, version: $1) },
            set: { try await client.setSecret(name: $0, $1) })
    }
}

/// Version history of one secret: list, view an older value (masked, re-masks), restore as a new version.
/// Values live only in memory (plus the version-keyed `SecretValueCache`) and are never logged.
@MainActor @Observable
final class VersionHistoryModel: Identifiable {
    enum Phase: Equatable { case loading, loaded, failed }

    let id = UUID()
    let vault: Vault
    let name: String
    private let ops: VersionHistoryOps
    private let cache: SecretValueCache
    private let remaskSeconds: () -> TimeInterval

    private(set) var phase: Phase = .loading
    private(set) var versions: [SecretItem] = []
    private(set) var selectedVersion: String?
    private(set) var selectedBundle: SecretBundle?
    private(set) var isLoadingValue = false
    private(set) var isRevealed = false
    private(set) var isRestoring = false
    private(set) var error: Error?
    private var remaskTask: Task<Void, Never>?

    init(
        vault: Vault, name: String, ops: VersionHistoryOps, cache: SecretValueCache = .shared,
        remaskSeconds: @escaping () -> TimeInterval = SecretDetailModel.configuredRemaskSeconds
    ) {
        self.vault = vault
        self.name = name
        self.ops = ops
        self.cache = cache
        self.remaskSeconds = remaskSeconds
    }

    // MARK: Derived

    /// Current version = newest by created date (Azure returns them unordered).
    var currentVersion: String? { versions.first?.version }

    func isCurrent(_ item: SecretItem) -> Bool { item.version != nil && item.version == currentVersion }

    var selectedItem: SecretItem? { versions.first { $0.version == selectedVersion } }

    var canRestore: Bool {
        guard !isRestoring, let v = selectedVersion, selectedBundle?.value != nil else { return false }
        return v != currentVersion
    }

    var displayValue: String { isRevealed ? (selectedBundle?.value ?? "") : "" }

    // MARK: Load

    func load() async {
        phase = .loading
        error = nil
        do {
            let items = try await ops.list(name)
            versions = Self.sorted(items)
            phase = .loaded
            if let first = versions.first?.version { await select(first) }
        } catch {
            self.error = error
            phase = .failed
        }
    }

    /// Newest first (created, then updated); items without dates last.
    static func sorted(_ items: [SecretItem]) -> [SecretItem] {
        items.sorted {
            let a = $0.attributes?.created ?? $0.attributes?.updated ?? .distantPast
            let b = $1.attributes?.created ?? $1.attributes?.updated ?? .distantPast
            return a > b
        }
    }

    /// Selects a version and fetches its value (masked).
    func select(_ version: String) async {
        mask()
        selectedVersion = version
        selectedBundle = nil
        error = nil
        let key = cacheKey(version)
        if let hit = cache.get(key) {
            selectedBundle = hit
            return
        }
        isLoadingValue = true
        defer { isLoadingValue = false }
        do {
            let bundle = try await ops.get(name, version)
            guard selectedVersion == version else { return }
            cache.set(key, bundle)
            selectedBundle = bundle
        } catch {
            guard selectedVersion == version else { return }
            self.error = error
        }
    }

    // MARK: Masking

    func reveal() {
        guard selectedBundle?.value != nil else { return }
        isRevealed = true
        remaskTask?.cancel()
        let seconds = max(1, remaskSeconds())
        remaskTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.isRevealed = false
        }
    }

    func mask() {
        remaskTask?.cancel()
        remaskTask = nil
        isRevealed = false
    }

    func toggleReveal() { isRevealed ? mask() : reveal() }

    /// Masks and drops values (sheet dismissed / app locked).
    func clear() {
        mask()
        selectedBundle = nil
        selectedVersion = nil
        for v in versions.compactMap(\.version) { cache.remove(cacheKey(v)) }
    }

    // MARK: Restore

    /// Writes the selected old value (+ contentType/tags/attributes) as a new current version.
    /// Undo re-sets the value that was current before.
    func restore() async -> SecretSaveResult? {
        guard canRestore, let old = selectedBundle else { return nil }
        isRestoring = true
        error = nil
        defer { isRestoring = false }
        let (ops, name) = (ops, name)
        do {
            let current = try? await ops.get(name, nil)
            _ = try await ops.set(name, SecretEditorModel.request(from: old))
            let undo: (@Sendable () async throws -> Void)? = current.flatMap { $0.value == nil ? nil : $0 }.map {
                prev in
                { _ = try await ops.set(name, SecretEditorModel.request(from: prev)) }
            }
            return SecretSaveResult(
                name: name, isNew: false, message: "Restored older version of \(name)", undo: undo)
        } catch {
            self.error = error
            return nil
        }
    }

    private func cacheKey(_ version: String) -> SecretValueCache.Key {
        .init(vault: vault.vaultUri.absoluteString, name: name, version: version)
    }
}
