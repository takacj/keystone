import AzureARM
import Foundation
import KeyVaultSecrets
import Testing

@testable import Secreter

@MainActor
@Suite struct VersionHistoryModelTests {
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

    private nonisolated static func item(_ v: String, created: Int) -> SecretItem {
        let json =
            #"{"id":"https://v.vault.azure.net/secrets/s/\#(v)","attributes":{"enabled":true,"created":\#(created)}}"#
        return try! JSONDecoder().decode(SecretItem.self, from: Data(json.utf8))
    }

    private nonisolated static func bundle(_ v: String, value: String) -> SecretBundle {
        let json =
            #"{"id":"https://v.vault.azure.net/secrets/s/\#(v)","value":"\#(value)","contentType":"text/plain","tags":{"a":"1"}}"#
        return try! JSONDecoder().decode(SecretBundle.self, from: Data(json.utf8))
    }

    private func model(_ log: Log, cache: SecretValueCache = SecretValueCache(), remask: TimeInterval = 20)
        -> VersionHistoryModel
    {
        let ops = VersionHistoryOps(
            list: { _ in [Self.item("v1", created: 100), Self.item("v3", created: 300), Self.item("v2", created: 200)]
            },
            get: { _, v in
                log.add("get:\(v ?? "current")")
                return Self.bundle(v ?? "v3", value: "val-\(v ?? "v3")")
            },
            set: { name, req in
                log.add("set:\(name):\(req.value):\(req.contentType ?? "-")")
                return Self.bundle("v4", value: req.value)
            })
        return VersionHistoryModel(vault: vault, name: "s", ops: ops, cache: cache, remaskSeconds: { remask })
    }

    @Test func loadsNewestFirstAndSelectsCurrent() async {
        let m = model(Log())
        await m.load()
        #expect(m.versions.compactMap(\.version) == ["v3", "v2", "v1"])
        #expect(m.currentVersion == "v3" && m.selectedVersion == "v3")
        #expect(!m.canRestore)
    }

    @Test func selectOlderIsMaskedUntilRevealed() async {
        let m = model(Log())
        await m.load()
        await m.select("v1")
        #expect(m.canRestore && !m.isRevealed && m.displayValue.isEmpty)
        m.reveal()
        #expect(m.displayValue == "val-v1")
        m.mask()
        #expect(m.displayValue.isEmpty)
    }

    @Test func remasksAfterDelay() async throws {
        let m = model(Log(), remask: 0.01)
        await m.load()
        await m.select("v1")
        m.reveal()
        try await Task.sleep(for: .milliseconds(1300))
        #expect(!m.isRevealed)
    }

    @Test func cacheAvoidsRefetch() async {
        let log = Log()
        let m = model(log)
        await m.load()
        await m.select("v1")
        await m.select("v2")
        await m.select("v1")
        #expect(log.all.filter { $0 == "get:v1" }.count == 1)
    }

    @Test func restoreSetsOldValueAndUndoRestoresCurrent() async throws {
        let log = Log()
        let m = model(log)
        await m.load()
        await m.select("v1")
        let result = await m.restore()
        #expect(result?.name == "s" && result?.undo != nil)
        #expect(log.all.contains("set:s:val-v1:text/plain"))
        try await result?.undo?()
        #expect(log.all.last == "set:s:val-v3:text/plain")
    }

    @Test func cannotRestoreCurrent() async {
        let m = model(Log())
        await m.load()
        #expect(await m.restore() == nil)
    }
}
