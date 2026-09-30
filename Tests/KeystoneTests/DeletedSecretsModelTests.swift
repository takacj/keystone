import AzureARM
import AzureCore
import Foundation
import KeyVaultSecrets
import Testing

@testable import Keystone

@MainActor
@Suite struct DeletedSecretsModelTests {
    private func vault(protected: Bool) -> Vault {
        Vault(
            id: "/subscriptions/s/resourceGroups/rg/providers/Microsoft.KeyVault/vaults/v", name: "v",
            location: "westeurope",
            resourceGroup: "rg", subscriptionId: "s", vaultUri: URL(string: "https://v.vault.azure.net")!,
            enablePurgeProtection: protected)
    }

    private final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []
        func add(_ s: String) { lock.withLock { items.append(s) } }
        var all: [String] { lock.withLock { items.sorted() } }
    }

    private func model(protected: Bool, log: Log, failing: Set<String> = []) -> DeletedSecretsModel {
        let ops = DeletedSecretsOps(
            list: { AsyncThrowingStream { $0.finish() } },
            recover: { n in
                if failing.contains(n) { throw AzureAPIError.forbidden(nil) }
                log.add("recover:\(n)")
            },
            purge: { log.add("purge:\($0)") })
        let m = DeletedSecretsModel(opsFactory: { _ in ops })
        m.setForTesting(vault: vault(protected: protected), rows: ["a", "b", "c"].map { DeletedSecretRow(name: $0) })
        return m
    }

    @Test func recoverRemovesRowsAndReportsFailures() async {
        let log = Log()
        var recovered = false
        let m = model(protected: false, log: log, failing: ["b"])
        m.onRecovered = { recovered = true }
        let ok = await m.recover(["a", "b"])
        #expect(ok == ["a"])
        #expect(m.rows.map(\.name) == ["b", "c"])
        #expect(m.failures.map(\.name) == ["b"])
        #expect(recovered)
        #expect(log.all == ["recover:a"])
    }

    @Test func purgeWorksWithoutProtection() async {
        let log = Log()
        let m = model(protected: false, log: log)
        #expect(await m.purge(["a", "c"]) == ["a", "c"])
        #expect(m.rows.map(\.name) == ["b"])
        #expect(log.all == ["purge:a", "purge:c"])
    }

    @Test func purgeRefusedWithPurgeProtection() async {
        let log = Log()
        let m = model(protected: true, log: log)
        #expect(m.purgeProtected)
        #expect(await m.purge(["a"]).isEmpty)
        #expect(m.rows.count == 3)
        #expect(log.all.isEmpty)
    }

    @Test func softDeleteRemovesRowsAndCollectsFailures() async {
        let s = SecretsModel()
        await s.load(vault: vault(protected: false))  // sets vault (no client → returns)
        s.setRowsForTesting(
            ["x", "y", "z"].map { name in
                let json = Data(#"{"id":"https://v.vault.azure.net/secrets/\#(name)"}"#.utf8)
                return SecretRow(try! JSONDecoder().decode(SecretItem.self, from: json))
            })
        s.selection = ["x", "y"]
        let failed = await s.delete(names: ["x", "y"]) { _, name in
            if name == "y" { throw AzureAPIError.conflict(nil) }
        }
        #expect(s.rows.map(\.name) == ["y", "z"])
        #expect(failed.map(\.name) == ["y"])
        #expect(DeletedConflict.isConflict(failed[0].error))
        #expect(s.selection == ["y"])
    }
}
