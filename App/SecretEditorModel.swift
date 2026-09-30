import AzureARM
import AzureCore
import Foundation
import KeyVaultSecrets
import Observation

/// Write operations the editor needs (seam for tests).
struct SecretEditorOps: Sendable {
    var set: @Sendable (String, SetSecretRequest) async throws -> SecretBundle
    var update: @Sendable (String, String, UpdateSecretRequest) async throws -> SecretBundle

    init(
        set: @escaping @Sendable (String, SetSecretRequest) async throws -> SecretBundle,
        update: @escaping @Sendable (String, String, UpdateSecretRequest) async throws -> SecretBundle
    ) {
        self.set = set
        self.update = update
    }

    init(client: KeyVaultSecretsClient) {
        self.init(
            set: { try await client.setSecret(name: $0, $1) },
            update: { try await client.updateSecret(name: $0, version: $1, $2) }
        )
    }
}

/// Result of a successful save; `undo` reverts it (restores the previous value/metadata).
struct SecretSaveResult {
    let name: String
    let isNew: Bool
    let message: String
    let undo: (@Sendable () async throws -> Void)?
}

/// Editor sheet state for creating a secret or editing one (new version and/or metadata PATCH).
/// The value is held only in memory and never logged.
@MainActor @Observable
final class SecretEditorModel: Identifiable {
    struct Tag: Identifiable, Equatable {
        let id = UUID()
        var key = ""
        var value = ""
    }

    enum Mode { case create, edit }

    let id = UUID()
    let mode: Mode
    let vault: Vault
    private let original: SecretBundle?
    private let ops: SecretEditorOps

    var name: String
    var value: String
    var contentType: String
    var tags: [Tag]
    var enabled: Bool
    var hasNotBefore: Bool
    var notBefore: Date
    var hasExpiry: Bool
    var expires: Date

    private(set) var isSaving = false
    private(set) var error: Error?
    /// Set on create 409 (name is in Deleted secrets) → drive `.deletedConflictPrompt`.
    var conflictName: String?

    init(vault: Vault, ops: SecretEditorOps, editing bundle: SecretBundle? = nil) {
        self.vault = vault
        self.ops = ops
        original = bundle
        mode = bundle == nil ? .create : .edit
        name = bundle?.name ?? ""
        value = bundle?.value ?? ""
        contentType = bundle?.contentType ?? ""
        tags = (bundle?.tags ?? [:]).sorted { $0.key < $1.key }.map { Tag(key: $0.key, value: $0.value) }
        enabled = bundle?.attributes?.enabled ?? true
        hasNotBefore = bundle?.attributes?.notBefore != nil
        notBefore = bundle?.attributes?.notBefore ?? Date()
        hasExpiry = bundle?.attributes?.expires != nil
        expires = bundle?.attributes?.expires ?? Date().addingTimeInterval(86400 * 365)
    }

    // MARK: Derived

    var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Azure Key Vault names: 1–127 chars, alphanumerics and dashes.
    static func isValidName(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 127
            && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    var nameError: String? {
        guard mode == .create, !trimmedName.isEmpty, !Self.isValidName(trimmedName) else { return nil }
        return "Use 1–127 letters, digits and dashes."
    }

    var dateError: String? {
        hasNotBefore && hasExpiry && expires <= notBefore ? "Expiry must be after activation." : nil
    }

    var tagError: String? {
        let keys = tags.map { $0.key.trimmingCharacters(in: .whitespaces) }
        if keys.contains(where: \.isEmpty) && tags.contains(where: { !$0.value.isEmpty || !$0.key.isEmpty }) {
            return "Tags need a key."
        }
        let named = keys.filter { !$0.isEmpty }
        return Set(named).count == named.count ? nil : "Duplicate tag keys."
    }

    var valueChanged: Bool { mode == .create || value != (original?.value ?? "") }

    var hasChanges: Bool {
        guard let original else { return true }
        return valueChanged || metadataRequest(for: original) != nil
    }

    var canSave: Bool {
        guard !isSaving, nameError == nil, dateError == nil, tagError == nil else { return false }
        if mode == .create { return Self.isValidName(trimmedName) && !value.isEmpty }
        return !value.isEmpty && hasChanges
    }

    var currentTags: [String: String] {
        var out: [String: String] = [:]
        for t in tags {
            let k = t.key.trimmingCharacters(in: .whitespaces)
            if !k.isEmpty { out[k] = t.value }
        }
        return out
    }

    var currentAttributes: SecretAttributes {
        SecretAttributes(
            enabled: enabled, notBefore: hasNotBefore ? Self.whole(notBefore) : nil,
            expires: hasExpiry ? Self.whole(expires) : nil)
    }

    private var currentContentType: String? {
        let t = contentType.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : t
    }

    private static func whole(_ d: Date) -> Date { Date(timeIntervalSince1970: d.timeIntervalSince1970.rounded(.down)) }

    /// PATCH body when metadata differs from `bundle`, else nil.
    private func metadataRequest(for bundle: SecretBundle) -> UpdateSecretRequest? {
        let attrs = bundle.attributes
        let same =
            (currentContentType ?? "") == (bundle.contentType ?? "")
            && currentTags == (bundle.tags ?? [:])
            && enabled == (attrs?.enabled ?? true)
            && currentAttributes.notBefore.map(Self.whole) == attrs?.notBefore.map(Self.whole)
            && currentAttributes.expires.map(Self.whole) == attrs?.expires.map(Self.whole)
        if same { return nil }
        return UpdateSecretRequest(
            contentType: currentContentType ?? "", tags: currentTags, attributes: currentAttributes)
    }

    /// PATCH can't clear dates (nil = unchanged), so clearing one needs a new version instead.
    private func clearsDate(of bundle: SecretBundle) -> Bool {
        (bundle.attributes?.notBefore != nil && !hasNotBefore) || (bundle.attributes?.expires != nil && !hasExpiry)
    }

    // MARK: Save

    /// Saves; nil on failure (`error` / `conflictName` set).
    func save() async -> SecretSaveResult? {
        guard canSave else { return nil }
        isSaving = true
        error = nil
        defer { isSaving = false }
        let ops = ops
        do {
            guard let original else { return try await create(ops) }
            let secretName = original.name
            if valueChanged || clearsDate(of: original) {
                let request = SetSecretRequest(
                    value: value, contentType: currentContentType, tags: currentTags, attributes: currentAttributes)
                _ = try await ops.set(secretName, request)
                let previous = Self.request(from: original)
                return SecretSaveResult(
                    name: secretName, isNew: false, message: "Saved new version of \(secretName)",
                    undo: { _ = try await ops.set(secretName, previous) })
            }
            guard let patch = metadataRequest(for: original) else { return nil }
            let version = original.version ?? ""
            _ = try await ops.update(secretName, version, patch)
            let revert = UpdateSecretRequest(
                contentType: original.contentType ?? "", tags: original.tags ?? [:],
                attributes: SecretAttributes(
                    enabled: original.attributes?.enabled ?? true, notBefore: original.attributes?.notBefore,
                    expires: original.attributes?.expires))
            return SecretSaveResult(
                name: secretName, isNew: false, message: "Updated \(secretName)",
                undo: { _ = try await ops.update(secretName, version, revert) })
        } catch {
            if mode == .create, DeletedConflict.isConflict(error) {
                conflictName = trimmedName
            } else {
                self.error = error
            }
            return nil
        }
    }

    private func create(_ ops: SecretEditorOps) async throws -> SecretSaveResult {
        let secretName = trimmedName
        _ = try await ops.set(
            secretName,
            SetSecretRequest(
                value: value, contentType: currentContentType, tags: currentTags.isEmpty ? nil : currentTags,
                attributes: currentAttributes))
        return SecretSaveResult(name: secretName, isNew: true, message: "Created \(secretName)", undo: nil)
    }

    /// Request that recreates `bundle` as a new version.
    static func request(from bundle: SecretBundle) -> SetSecretRequest {
        SetSecretRequest(
            value: bundle.value ?? "", contentType: bundle.contentType, tags: bundle.tags,
            attributes: SecretAttributes(
                enabled: bundle.attributes?.enabled, notBefore: bundle.attributes?.notBefore,
                expires: bundle.attributes?.expires))
    }
}

/// Owns the editor sheet and the undo toast. Wired in `MainView`.
@MainActor @Observable
final class SecretEditorCoordinator {
    struct Toast: Identifiable {
        let id = UUID()
        let message: String
        let undo: (@Sendable () async throws -> Void)?
    }

    static let toastSeconds: TimeInterval = 8

    var sheet: SecretEditorModel?
    private(set) var toast: Toast?
    private(set) var undoError: Error?

    /// Builds write ops for a vault (nil when signed out).
    var opsFactory: (Vault) -> SecretEditorOps? = { _ in nil }
    /// Called after any successful write (incl. undo): refresh lists/detail, invalidate value cache.
    var onChanged: (Vault, String) async -> Void = { _, _ in }
    private var toastTask: Task<Void, Never>?

    func beginCreate(vault: Vault?) {
        guard let vault, let ops = opsFactory(vault) else { return }
        sheet = SecretEditorModel(vault: vault, ops: ops)
    }

    func beginEdit(vault: Vault?, bundle: SecretBundle?) {
        guard let vault, let bundle, bundle.value != nil, let ops = opsFactory(vault) else { return }
        sheet = SecretEditorModel(vault: vault, ops: ops, editing: bundle)
    }

    /// Saves the open sheet; closes it and shows the toast on success.
    func save() async {
        guard let model = sheet, let result = await model.save() else { return }
        sheet = nil
        await onChanged(model.vault, result.name)
        show(Toast(message: result.message, undo: result.undo), vault: model.vault, name: result.name)
    }

    /// Reports a write made elsewhere (e.g. version restore): refresh + undo toast.
    func completed(_ result: SecretSaveResult, vault: Vault) async {
        await onChanged(vault, result.name)
        show(Toast(message: result.message, undo: result.undo), vault: vault, name: result.name)
    }

    func undo() async {
        guard let current = toast, let undo = current.undo, let (vault, name) = lastContext else { return }
        dismissToast()
        do {
            try await undo()
            await onChanged(vault, name)
        } catch {
            undoError = error
        }
    }

    func dismissToast() {
        toastTask?.cancel()
        toast = nil
    }

    func clearUndoError() { undoError = nil }

    private func show(_ t: Toast, vault: Vault, name: String) {
        toastTask?.cancel()
        toast = t
        lastContext = (vault, name)
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.toastSeconds))
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    private var lastContext: (Vault, String)?
}
