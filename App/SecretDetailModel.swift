import AppKit
import AzureARM
import Foundation
import KeyVaultSecrets
import Observation

/// Detail of one selected secret: lazy-masked value, auto re-mask, concealed copy, JSON view.
/// Values live only in memory (here and in `SecretValueCache`); never logged.
@MainActor @Observable
final class SecretDetailModel {
    nonisolated static let remaskDefaultsKey = "remaskSeconds"
    nonisolated static let defaultRemaskSeconds: TimeInterval = 20
    static let toastSeconds: TimeInterval = 2

    enum Phase: Equatable { case idle, loading, loaded, failed }

    private(set) var name: String?
    private(set) var phase: Phase = .idle
    private(set) var error: Error?
    private(set) var bundle: SecretBundle?
    private(set) var isRevealed = false
    private(set) var showCopiedToast = false
    var formatJSON = false

    var clientFactory: (Vault) -> KeyVaultSecretsClient?
    /// Seconds until a revealed value re-masks.
    var remaskSeconds: () -> TimeInterval
    var writePasteboard: (String) -> Void
    private let cache: SecretValueCache
    private var vault: Vault?
    private var generation = 0
    private var remaskTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?

    init(
        cache: SecretValueCache = .shared,
        clientFactory: @escaping (Vault) -> KeyVaultSecretsClient? = { _ in nil },
        remaskSeconds: @escaping () -> TimeInterval = SecretDetailModel.configuredRemaskSeconds,
        writePasteboard: @escaping (String) -> Void = SecretDetailModel.writeConcealed
    ) {
        self.cache = cache
        self.clientFactory = clientFactory
        self.remaskSeconds = remaskSeconds
        self.writePasteboard = writePasteboard
    }

    var value: String? { bundle?.value }

    /// Value as shown when revealed (pretty-printed when `formatJSON` and the value is JSON).
    var displayValue: String {
        guard let value else { return "" }
        if formatJSON, let pretty = Self.prettyJSON(value) { return pretty }
        return value
    }

    var isJSON: Bool { value.flatMap(Self.prettyJSON) != nil }
    var isMultiline: Bool { value?.contains("\n") ?? false }

    // MARK: Loading

    /// Shows `name` of `vault` (nil name → empty). Fetches the value unless cached.
    func show(vault: Vault?, name: String?) async {
        generation += 1
        let gen = generation
        mask()
        self.vault = vault
        self.name = name
        error = nil
        bundle = nil
        guard let vault, let name else {
            phase = .idle
            return
        }
        let key = cacheKey(vault, name)
        if let hit = cache.get(key) {
            bundle = hit
            phase = .loaded
            return
        }
        guard let client = clientFactory(vault) else {
            phase = .idle
            return
        }
        phase = .loading
        do {
            let result = try await client.getSecret(name: name)
            guard gen == generation else { return }
            cache.set(key, result)
            bundle = result
            phase = .loaded
        } catch is CancellationError {
            return
        } catch {
            guard gen == generation else { return }
            self.error = error
            phase = .failed
        }
    }

    func retry() async { await show(vault: vault, name: name) }

    // MARK: Reveal / mask

    func reveal() {
        guard value != nil else { return }
        isRevealed = true
        remaskTask?.cancel()
        let seconds = max(1, remaskSeconds())
        remaskTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.mask()
        }
    }

    func mask() {
        remaskTask?.cancel()
        remaskTask = nil
        isRevealed = false
    }

    func toggleReveal() { isRevealed ? mask() : reveal() }

    // MARK: Copy

    /// Copies the value with `org.nspasteboard.ConcealedType`; no auto-clear.
    func copy() {
        guard let value else { return }
        writePasteboard(value)
        showCopiedToast = true
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.toastSeconds))
            guard !Task.isCancelled else { return }
            self?.showCopiedToast = false
        }
    }

    // MARK: Lifecycle

    /// Context switch: drop everything for the previous context.
    func contextChanged() { clear() }

    /// Touch ID lock (#98): mask, forget the value, empty the cache.
    func clear() {
        generation += 1
        mask()
        cache.clear()
        bundle = nil
        error = nil
        phase = .idle
        name = nil
        vault = nil
    }

    // MARK: Helpers

    private func cacheKey(_ vault: Vault, _ name: String) -> SecretValueCache.Key {
        .init(vault: vault.vaultUri.absoluteString, name: name)
    }

    nonisolated static func configuredRemaskSeconds() -> TimeInterval {
        let v = UserDefaults.standard.double(forKey: remaskDefaultsKey)
        return v > 0 ? v : defaultRemaskSeconds
    }

    nonisolated static func writeConcealed(_ value: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(value, forType: .string)
        pb.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
    }

    /// Pretty JSON for objects/arrays; nil when `text` isn't one.
    nonisolated static func prettyJSON(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.first == "{" || trimmed.first == "[",
            let obj = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)),
            let data = try? JSONSerialization.data(
                withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
            let out = String(data: data, encoding: .utf8)
        else { return nil }
        return out
    }
}

#if DEBUG
    extension SecretDetailModel {
        func setBundleForTesting(_ b: SecretBundle) {
            bundle = b
            phase = .loaded
        }
    }
#endif
