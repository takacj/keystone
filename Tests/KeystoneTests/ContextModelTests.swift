import AzureARM
import AzureAuth
import AzureCore
import Foundation
import Persistence
import Testing

@testable import Keystone

private final class Log: @unchecked Sendable {
    let lock = NSLock()
    var urls: [String] = []
}

private struct Fake: HTTPTransport, TokenProvider {
    let log: Log
    var gate: Bool = false
    var twoVaults: Bool = false
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!.absoluteString
        log.lock.withLock { log.urls.append(url) }
        if gate && url.contains("/subscriptions/") { try await Task.sleep(for: .seconds(30)) }
        let body: String
        if url.contains("/providers/Microsoft.KeyVault/vaults") {
            let sub = url.components(separatedBy: "/subscriptions/")[1].components(separatedBy: "/")[0]
            let names = twoVaults ? ["kv-\(sub)", "kvb-\(sub)"] : ["kv-\(sub)"]
            let items = names.map {
                #"{"id":"/subscriptions/\#(sub)/resourceGroups/rg/providers/Microsoft.KeyVault/vaults/\#($0)","name":"\#($0)","location":"we","properties":{"vaultUri":"https://\#($0).vault.azure.net/"}}"#
            }
            body = #"{"value":["# + items.joined(separator: ",") + "]}"
        } else if url.contains("/subscriptions?") {
            body =
                #"{"value":[{"subscriptionId":"s1","displayName":"One","state":"Enabled"},{"subscriptionId":"s2","displayName":"Two","state":"Enabled"}]}"#
        } else {
            body = #"{"value":[{"tenantId":"t1","displayName":"T1"},{"tenantId":"t2","displayName":"T2"}]}"#
        }
        return (
            Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        )
    }
    func token(tenant: String, resource: AzureResource) async throws -> AccessToken {
        AccessToken(value: "t", expiresOn: .distantFuture)
    }
    func invalidate(tenant: String, resource: AzureResource) async {}
}

@MainActor
@Suite struct ContextModelTests {
    let account = AccountProfile(
        id: UUID(), displayName: "A", upn: "a@b.c", homeTenantId: "t1", profileDir: URL(fileURLWithPath: "/tmp/x"))

    private func makeStore() -> ContextStateStore {
        ContextStateStore(
            fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).json"))
    }

    private func client(_ fake: Fake) -> ARMClient { ARMClient(tokenProvider: fake, transport: fake) }

    private func settle(_ model: ContextModel, until done: @MainActor () -> Bool) async {
        for _ in 0..<200 where !done() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func loadsChainAndPersistsSelection() async {
        let store = makeStore()
        let model = ContextModel(store: store)
        model.switchAccount(account, client: client(Fake(log: Log())))
        await settle(model) { model.vaultsPhase == .idle && !model.vaults.isEmpty }
        #expect(model.selectedTenantID == "t1")
        #expect(model.selectedSubscriptionID == "s1")
        #expect(model.vaults.map(\.name) == ["kv-s1"])
        #expect(model.selectedVaultID == nil)

        model.selectVault(model.vaults[0].id)
        model.toggleFavorite(model.vaults[0])
        model.selectSubscription("s2")
        await settle(model) { model.vaults.first?.name == "kv-s2" }
        #expect(store.load(accountID: account.id).subscriptionId == "s2")
        #expect(store.load(accountID: account.id).recents.count == 1)

        // Fresh model restores subscription and (favorites) but not a vault from another sub.
        let model2 = ContextModel(store: store)
        model2.switchAccount(account, client: client(Fake(log: Log())))
        await settle(model2) { !model2.vaults.isEmpty }
        #expect(model2.selectedSubscriptionID == "s2")
        #expect(model2.favoriteIDs.count == 1)
        #expect(model2.selectedVaultID == nil)
    }

    @Test func restoresLastVault() async {
        let store = makeStore()
        let id = "/subscriptions/s1/resourceGroups/rg/providers/Microsoft.KeyVault/vaults/kv-s1"
        store.save(AccountContextState(tenantId: "t2", subscriptionId: "s1", vaultId: id), accountID: account.id)
        let model = ContextModel(store: store)
        model.switchAccount(account, client: client(Fake(log: Log())))
        await settle(model) { model.selectedVaultID != nil }
        #expect(model.selectedTenantID == "t2")
        #expect(model.selectedVault?.name == "kv-s1")
    }

    @Test func switchCancelsInFlightLoad() async {
        let model = ContextModel(store: makeStore())
        model.switchAccount(account, client: client(Fake(log: Log(), gate: true)))
        await settle(model) { model.subscriptionsPhase == .loading }
        model.switchAccount(nil, client: nil)
        #expect(model.subscriptionsPhase == .idle)
        #expect(model.tenants.isEmpty)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(model.subscriptions.isEmpty)
    }

    private func loadedTwoVaults(_ store: ContextStateStore) async -> ContextModel {
        let model = ContextModel(store: store)
        model.switchAccount(account, client: client(Fake(log: Log(), twoVaults: true)))
        await settle(model) { model.vaultsPhase == .idle && model.vaults.count == 2 }
        return model
    }

    /// Seeds persisted recents as [B, A] via a first session; returns a fresh session plus A and B.
    private func seededRecents(_ store: ContextStateStore) async -> (ContextModel, Vault, Vault) {
        let first = await loadedTwoVaults(store)
        let a = first.vaults.first { $0.name == "kv-s1" }!
        let b = first.vaults.first { $0.name == "kvb-s1" }!
        first.selectVault(a.id)
        first.selectVault(b.id)
        return (await loadedTwoVaults(store), a, b)
    }

    @Test func sidebarRecentsStayStable() async {
        let store = makeStore()
        let (model, a, b) = await seededRecents(store)
        #expect(model.recentVaults.map(\.name) == ["kvb-s1", "kv-s1"])
        model.selectVault(a.id)
        model.selectVault(b.id)
        model.selectVault(a.id)
        #expect(model.recentVaults.map(\.name) == ["kvb-s1", "kv-s1"])
        #expect(store.load(accountID: account.id).recents == [a.id, b.id])

        // reload keeps the snapshot.
        model.reload()
        await settle(model) { model.vaults.count == 2 }
        #expect(model.recentVaults.map(\.name) == ["kvb-s1", "kv-s1"])
    }

    @Test func unseenVaultNotAddedToSidebarRecents() async {
        let store = makeStore()
        let model = await loadedTwoVaults(store)
        let a = model.vaults.first { $0.name == "kv-s1" }!
        model.selectVault(a.id)
        #expect(model.recentVaults.isEmpty)
        #expect(store.load(accountID: account.id).recents == [a.id])
    }

    @Test func favoritesExcludedFromRecents() async {
        let (model, a, _) = await seededRecents(makeStore())
        model.toggleFavorite(a)
        #expect(model.recentVaults.map(\.name) == ["kvb-s1"])
    }

    @Test func refreshVaultsKeepsSelection() async {
        let model = await loadedTwoVaults(makeStore())
        let b = model.vaults.first { $0.name == "kvb-s1" }!
        model.selectVault(b.id)
        let generation = model.contextGeneration
        model.refreshVaults()
        #expect(model.vaultsPhase == .loading)
        #expect(model.vaults.count == 2)
        #expect(model.selectedVaultID == b.id)
        await settle(model) { model.vaultsPhase == .idle }
        #expect(model.selectedVaultID == b.id)
        #expect(model.vaults.count == 2)
        #expect(model.contextGeneration == generation)
    }

    @Test func filterAndPortalURL() {
        let vault = Vault(
            id: "/subscriptions/s/resourceGroups/rg/providers/Microsoft.KeyVault/vaults/kv", name: "kv",
            location: "we", resourceGroup: "rg", subscriptionId: "s",
            vaultUri: URL(string: "https://kv.vault.azure.net/")!)
        #expect(
            ContextModel.portalURL(for: vault, tenant: "t")?.absoluteString
                == "https://portal.azure.com/#@t/resource/subscriptions/s/resourceGroups/rg/providers/Microsoft.KeyVault/vaults/kv/overview"
        )
    }
}
