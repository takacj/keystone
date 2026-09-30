import AzureARM
import Foundation
import Search
import Testing

@testable import Secreter

@MainActor
@Suite struct CommandPaletteModelTests {
    private func vault(_ name: String, sub: String) -> Vault {
        Vault(
            id: "/subscriptions/\(sub)/resourceGroups/rg/providers/Microsoft.KeyVault/vaults/\(name)", name: name,
            location: "westeurope", resourceGroup: "rg", subscriptionId: sub,
            vaultUri: URL(string: "https://\(name).vault.azure.net")!)
    }

    private func makeModel() async -> (CommandPaletteModel, [String: [String]]) {
        let a = vault("kv-alpha", sub: "s1")
        let b = vault("kv-beta", sub: "s2")
        let names = ["kv-alpha": ["db-password", "api-key"], "kv-beta": ["db-conn", "jwt"]]
        let index = NameIndex(lister: { v in names[v.name] ?? [] })
        let m = CommandPaletteModel(index: index)
        m.discover = { _ in [a, b] }
        m.currentSubscription = { "s1" }
        m.startIndexing(tenant: "t")
        await m.indexTask?.value
        return (m, names)
    }

    @Test func scopeFiltersResults() async {
        let (m, _) = await makeModel()
        m.query = "db"
        await m.refresh()
        #expect(m.secretResults.map(\.secretName) == ["db-password"])
        m.scope = .allInTenant
        await m.refresh()
        #expect(Set(m.secretResults.compactMap(\.secretName)) == ["db-password", "db-conn"])
        #expect(m.progress?.isFinished == true && m.progress?.total == 2)
    }

    @Test func vaultsGroupedAndRanked() async {
        let (m, _) = await makeModel()
        m.scope = .allInTenant
        m.query = "beta"
        await m.refresh()
        #expect(m.vaultResults.map(\.vault.name) == ["kv-beta"])
        #expect(m.items.first?.id == m.selectedID)
    }

    @Test func copyNameAndValue() async {
        let (m, _) = await makeModel()
        var plain: String?
        var secret: String?
        m.writePlain = { plain = $0 }
        m.writeSecret = { secret = $0 }
        m.fetchValue = { _, name in "value-of-\(name)" }
        m.query = "api"
        await m.refresh()
        m.copyName()
        #expect(plain == "api-key")
        m.open()
        m.query = "api"
        await m.refresh()
        await m.copyValue()
        #expect(secret == "value-of-api-key")
        #expect(!m.isPresented)
    }

    @Test func openNavigates() async {
        let (m, _) = await makeModel()
        var target: (String, String?)?
        m.navigate = { v, n in target = (v.name, n) }
        m.open()
        m.query = "jwt"
        m.scope = .allInTenant
        await m.refresh()
        await m.openSelected()
        #expect(target?.0 == "kv-beta" && target?.1 == "jwt")
        #expect(!m.isPresented)
    }

    @Test func selectionMoves() async {
        let (m, _) = await makeModel()
        m.scope = .allInTenant
        m.query = "kv"
        await m.refresh()
        let first = m.selectedID
        m.moveSelection(1)
        #expect(m.selectedID != first)
        m.moveSelection(-5)
        #expect(m.selectedID == first)
    }
}

@MainActor
struct PaletteDefaultScopeTests {
    @Test func readsDefaultScopeFromDefaults() {
        let d = UserDefaults(suiteName: "PaletteScope-\(UUID())")!
        #expect(CommandPaletteModel(defaults: d).scope == .currentSubscription)
        d.set(CommandPaletteModel.Scope.allInTenant.storageValue, forKey: CommandPaletteModel.defaultScopeKey)
        #expect(CommandPaletteModel(defaults: d).scope == .allInTenant)
        d.set("garbage", forKey: CommandPaletteModel.defaultScopeKey)
        #expect(CommandPaletteModel(defaults: d).scope == .currentSubscription)
    }
}
