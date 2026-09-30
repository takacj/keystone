import AzureARM
import AzureCore
import Foundation
import KeyVaultSecrets
import Testing

@testable import Keystone

@MainActor
@Suite struct SecretEditorModelTests {
    private final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []
        func add(_ s: String) { lock.withLock { items.append(s) } }
        var all: [String] { lock.withLock { items } }
    }

    private let vault = Vault(
        id: "/subscriptions/s/resourceGroups/rg/providers/Microsoft.KeyVault/vaults/v", name: "v",
        location: "westeurope", resourceGroup: "rg", subscriptionId: "s",
        vaultUri: URL(string: "https://v.vault.azure.net")!)

    private func bundle(value: String = "old", tags: [String: String] = ["a": "1"]) -> SecretBundle {
        let json: [String: Any] = [
            "id": "https://v.vault.azure.net/secrets/s/v1", "value": value, "contentType": "text/plain",
            "tags": tags, "attributes": ["enabled": true],
        ]
        return try! JSONDecoder().decode(SecretBundle.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private nonisolated static func stub(_ id: String) -> SecretBundle {
        try! JSONDecoder().decode(SecretBundle.self, from: Data(#"{"id":"\#(id)"}"#.utf8))
    }

    private func ops(_ log: Log, setError: Error? = nil) -> SecretEditorOps {
        SecretEditorOps(
            set: { name, req in
                if let setError { throw setError }
                log.add("set:\(name):\(req.value)")
                return Self.stub("https://v.vault.azure.net/secrets/\(name)/v2")
            },
            update: { name, version, req in
                log.add(
                    "patch:\(name):\(version):\(req.attributes?.enabled.map(String.init) ?? "-"):\(req.tags?.count ?? -1)"
                )
                return Self.stub("https://v.vault.azure.net/secrets/\(name)/\(version)")
            })
    }

    @Test func nameValidation() {
        #expect(SecretEditorModel.isValidName("db-conn-1"))
        #expect(!SecretEditorModel.isValidName("bad_name"))
        #expect(!SecretEditorModel.isValidName(""))
    }

    @Test func createCallsSet() async {
        let log = Log()
        let m = SecretEditorModel(vault: vault, ops: ops(log))
        #expect(!m.canSave)
        m.name = "new-secret"
        m.value = "v"
        #expect(m.canSave)
        let r = await m.save()
        #expect(r?.name == "new-secret" && r?.isNew == true && r?.undo == nil)
        #expect(log.all == ["set:new-secret:v"])
    }

    @Test func createConflictSetsPrompt() async {
        let m = SecretEditorModel(vault: vault, ops: ops(Log(), setError: AzureAPIError.conflict(nil)))
        m.name = "x"
        m.value = "v"
        #expect(await m.save() == nil)
        #expect(m.conflictName == "x")
        #expect(m.error == nil)
    }

    @Test func valueChangeCreatesVersionAndUndoRestores() async throws {
        let log = Log()
        let m = SecretEditorModel(vault: vault, ops: ops(log), editing: bundle())
        #expect(!m.canSave)  // nothing changed
        m.value = "new"
        let r = await m.save()
        try await r?.undo?()
        #expect(log.all == ["set:s:new", "set:s:old"])
    }

    @Test func metadataOnlyPatchesAndUndoReverts() async throws {
        let log = Log()
        let m = SecretEditorModel(vault: vault, ops: ops(log), editing: bundle())
        m.enabled = false
        m.tags.append(.init(key: "b", value: "2"))
        let r = await m.save()
        try await r?.undo?()
        #expect(log.all == ["patch:s:v1:false:2", "patch:s:v1:true:1"])
    }

    @Test func clearingDateFallsBackToNewVersion() async {
        let log = Log()
        var b = bundle()
        b.attributes?.expires = Date(timeIntervalSince1970: 2_000_000_000)
        let m = SecretEditorModel(vault: vault, ops: ops(log), editing: b)
        m.hasExpiry = false
        _ = await m.save()
        #expect(log.all == ["set:s:old"])
    }

    @Test func validationErrors() {
        let m = SecretEditorModel(vault: vault, ops: ops(Log()), editing: bundle())
        m.hasNotBefore = true
        m.hasExpiry = true
        m.expires = m.notBefore.addingTimeInterval(-10)
        #expect(m.dateError != nil && !m.canSave)
        m.hasExpiry = false
        m.tags = [.init(key: "k", value: "1"), .init(key: "k", value: "2")]
        #expect(m.tagError != nil)
    }

    @Test func coordinatorSaveShowsToastAndUndoRefreshes() async {
        let log = Log()
        let c = SecretEditorCoordinator()
        c.opsFactory = { [ops = ops(log)] _ in ops }
        let changed = Log()
        c.onChanged = { _, name in changed.add(name) }
        c.beginEdit(vault: vault, bundle: bundle())
        c.sheet?.value = "new"
        await c.save()
        #expect(c.sheet == nil && c.toast?.undo != nil)
        await c.undo()
        #expect(c.toast == nil)
        #expect(log.all == ["set:s:new", "set:s:old"])
        #expect(changed.all == ["s", "s"])
    }
}
