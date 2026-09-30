import AzureCore
import Foundation
import Testing

@testable import AzureARM
@testable import Search

private func vault(_ n: String) -> Vault {
    Vault(
        id: "/subscriptions/s1/resourceGroups/rg/providers/Microsoft.KeyVault/vaults/\(n)", name: n,
        location: "westeurope", resourceGroup: "rg", subscriptionId: "s1",
        vaultUri: URL(string: "https://\(n).vault.azure.net/")!)
}

private final class Probe: @unchecked Sendable {
    let lock = NSLock()
    var running = 0, peak = 0, calls: [String: Int] = [:], sleeps: [TimeInterval] = []
    func enter(_ n: String) {
        lock.withLock {
            running += 1
            peak = max(peak, running)
            calls[n, default: 0] += 1
        }
    }
    func leave() { lock.withLock { running -= 1 } }
}

@Test func indexesAndSearchesWithConcurrencyLimit() async {
    let probe = Probe()
    let idx = NameIndex(concurrency: 4) { v in
        probe.enter(v.name)
        defer { probe.leave() }
        try await Task.sleep(for: .milliseconds(20))
        return ["db-password-\(v.name)", "api-key"]
    }
    let vaults = (0..<10).map { vault("v\($0)") }
    await idx.build(tenant: "t", vaults: vaults)
    #expect(probe.peak <= 4 && probe.peak > 1)
    let p = await idx.progress
    #expect(p == .init(total: 10, completed: 10, inaccessible: 0, secretCount: 20))
    let hits = await idx.search("api")
    #expect(hits.count == 10)
    #expect(await idx.search("PASSWORD-v3").map(\.secretName) == ["db-password-v3"])
    #expect(await idx.search("").isEmpty)
}

@Test func skipsInaccessibleVaults() async {
    let idx = NameIndex(maxRetries: 0) { v in
        switch v.name {
        case "a": throw AzureAPIError.forbidden(nil)
        case "b": throw AzureAPIError.unauthorized(nil)
        case "c": throw AzureAPIError.network(.cannotFindHost)
        default: return ["s"]
        }
    }
    let vs = ["a", "b", "c", "d"].map(vault)
    await idx.build(tenant: "t", vaults: vs)
    #expect(await idx.state(of: vs[0]) == .inaccessible(.forbidden))
    #expect(await idx.state(of: vs[1]) == .inaccessible(.unauthorized))
    #expect(await idx.state(of: vs[2]) == .inaccessible(.network))
    #expect(await idx.inaccessibleVaults.map(\.vault.name) == ["a", "b", "c"])
    #expect(await idx.progress.inaccessible == 3)
    #expect(await idx.search("s").count == 1)
}

@Test func retriesThrottledWithBackoff() async {
    let probe = Probe()
    let idx = NameIndex(
        maxRetries: 3, sleep: { d in probe.lock.withLock { probe.sleeps.append(d) } },
        lister: { v in
            probe.enter(v.name)
            probe.leave()
            if probe.lock.withLock({ probe.calls[v.name]! }) < 3 { throw AzureAPIError.throttled(retryAfter: nil, nil) }
            return ["ok"]
        })
    let v = vault("x")
    await idx.build(tenant: "t", vaults: [v])
    #expect(probe.calls["x"] == 3)
    #expect(probe.sleeps.count == 2 && probe.sleeps[1] > probe.sleeps[0] * 0.9)
    #expect(await idx.secretNames(in: v) == ["ok"])
}

private final class Clock: @unchecked Sendable {
    let lock = NSLock()
    var t = Date(timeIntervalSince1970: 1000)
    var date: Date { lock.withLock { t } }
    func advance(_ s: TimeInterval) { lock.withLock { t += s } }
}

@Test func ttlSkipsFreshAndRefreshesStale() async {
    let probe = Probe()
    let clock = Clock()
    let idx = NameIndex(
        ttl: 60, now: { clock.date },
        lister: { v in
            probe.enter(v.name)
            probe.leave()
            return ["s"]
        })
    let v = vault("a")
    await idx.build(tenant: "t", vaults: [v])
    await idx.build(tenant: "t", vaults: [v])
    #expect(probe.calls["a"] == 1)
    #expect(await !idx.isStale(v))
    clock.advance(61)
    #expect(await idx.isStale(v))
    await idx.build(tenant: "t", vaults: [v])
    #expect(probe.calls["a"] == 2)
    await idx.build(tenant: "t", vaults: [v], force: true)
    #expect(probe.calls["a"] == 3)
}

@Test func tenantSwitchResetsIndex() async {
    let idx = NameIndex { _ in ["s"] }
    await idx.build(tenant: "t1", vaults: [vault("a")])
    await idx.build(tenant: "t2", vaults: [vault("b")])
    #expect(await idx.search("s").map(\.vault.name) == ["b"])
    #expect(await idx.progress.total == 1)
}
