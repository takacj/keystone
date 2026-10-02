import AzureARM
import Foundation
import Search
import Testing

@testable import Keystone

@MainActor
@Suite struct ValueSearchModelTests {
    private func vault(_ name: String, sub: String = "s1") -> Vault {
        Vault(
            id: "/subscriptions/\(sub)/resourceGroups/rg/providers/Microsoft.KeyVault/vaults/\(name)", name: name,
            location: "westeurope", resourceGroup: "rg", subscriptionId: sub,
            vaultUri: URL(string: "https://\(name).vault.azure.net")!)
    }

    private func makeModel(_ vaults: [Vault]) -> ValueSearchModel {
        let values = ["kv-dev": ["a": "hit", "b": "miss"], "kv-prod": ["c": "hit"]]
        let m = ValueSearchModel()
        m.prodGuard = { ProdGuard() }
        m.currentVault = { vaults.first }
        m.subscriptionVaults = { vaults }
        m.subscriptionName = { _ in "Dev Subscription" }
        m.makeSearcher = {
            ValueSearcher(
                lister: { v in (values[v.name] ?? [:]).keys.sorted().map { .init(name: $0) } },
                fetcher: { v, name in values[v.name]?[name] })
        }
        m.open()
        m.value = "hit"
        return m
    }

    @Test func scansCurrentVaultByDefault() async {
        let m = makeModel([vault("kv-dev"), vault("kv-other")])
        await m.start()
        await m.scanTask?.value
        #expect(m.phase == .finished)
        #expect(m.matches.map(\.secretName) == ["a"])
        #expect(m.progress?.secretsScanned == 2)
    }

    @Test func productionVaultNeedsConfirmation() async {
        let m = makeModel([vault("kv-dev"), vault("kv-prod")])
        m.scope = .currentSubscription
        await m.start()
        #expect(m.pendingProduction?.map(\.name) == ["kv-prod"])
        #expect(m.phase == .idle && m.scanTask == nil)

        m.cancelProduction()
        #expect(m.pendingProduction == nil && m.scanTask == nil)

        await m.start()
        m.confirmProduction()
        await m.scanTask?.value
        #expect(Set(m.matches.map(\.secretName)) == ["a", "c"])
    }

    @Test func productionSubscriptionNeedsConfirmation() async {
        let m = makeModel([vault("kv-dev")])
        m.subscriptionName = { _ in "Contoso PROD" }
        await m.start()
        #expect(m.pendingProduction?.map(\.name) == ["kv-dev"])
    }

    @Test func lockClearsQueryAndResults() async {
        let m = makeModel([vault("kv-dev")])
        await m.start()
        await m.scanTask?.value
        #expect(!m.matches.isEmpty)
        m.lockChanged()
        #expect(m.value.isEmpty && m.matches.isEmpty && m.progress == nil)
        #expect(!m.isPresented && m.phase == .idle)
    }

    @Test func lockCancelsRunningScan() async {
        let m = makeModel([vault("kv-dev")])
        m.makeSearcher = {
            ValueSearcher(
                lister: { _ in (0..<500).map { .init(name: "s\($0)") } },
                fetcher: { _, _ in
                    try await Task.sleep(for: .milliseconds(5))
                    return "hit"
                })
        }
        await m.start()
        #expect(m.isScanning)
        let task = m.scanTask
        m.lockChanged()
        await task?.value
        #expect(m.matches.isEmpty && m.phase == .idle && m.scanTask == nil)
    }

    @Test func closeClearsAndOpenMatchNavigates() async throws {
        let m = makeModel([vault("kv-dev")])
        var opened: (String, String?)?
        m.navigate = { v, n in opened = (v.name, n) }
        await m.start()
        await m.scanTask?.value
        let match = try #require(m.matches.first)
        await m.openMatch(match)
        #expect(opened?.0 == "kv-dev" && opened?.1 == "a")
        #expect(!m.isPresented && m.value.isEmpty && m.matches.isEmpty)
    }

    @Test func noVaultFails() async {
        let m = makeModel([])
        await m.start()
        #expect(m.phase == .failed("Select a vault first."))
    }
}
