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
    func enter(_ key: String) -> Int {
        lock.withLock {
            running += 1
            peak = max(peak, running)
            calls[key, default: 0] += 1
            return calls[key]!
        }
    }
    func leave() { lock.withLock { running -= 1 } }
}

/// a: s1=Secret, s2=secret-123, s3 (disabled)=Secret; b: t1=Secret.
private let values: [String: [String: String]] = [
    "a": ["s1": "Secret", "s2": "my-secret-123", "s3": "Secret"],
    "b": ["t1": "Secret"],
]

private func searcher(probe: Probe = Probe(), concurrency: Int = 4) -> ValueSearcher {
    ValueSearcher(
        concurrency: concurrency, sleep: { _ in },
        lister: { v in
            (values[v.name] ?? [:]).keys.sorted().map { ValueSearcher.Candidate(name: $0, enabled: $0 != "s3") }
        },
        fetcher: { v, name in
            _ = probe.enter(name)
            defer { probe.leave() }
            return values[v.name]?[name]
        })
}

private func collect(
    _ s: ValueSearcher, _ q: ValueSearcher.Query, _ vaults: [Vault]
) async -> (matches: [String], skipped: [String: NameIndex.InaccessibleReason], last: ValueSearcher.Progress?) {
    var matches: [String] = []
    var skipped: [String: NameIndex.InaccessibleReason] = [:]
    var last: ValueSearcher.Progress?
    for await e in s.search(q, in: vaults) {
        switch e {
        case .match(let m): matches.append(m.vault.name + "/" + m.secretName)
        case .skipped(let v, let r): skipped[v.name] = r
        case .progress(let p): last = p
        }
    }
    return (matches.sorted(), skipped, last)
}

@Test func exactMatchIsCaseSensitiveByDefault() async {
    let r = await collect(searcher(), .init(value: "Secret"), [vault("a"), vault("b")])
    #expect(r.matches == ["a/s1", "b/t1"])
    var expected = ValueSearcher.Progress(vaultsTotal: 2)
    expected.vaultsScanned = 2
    expected.secretsTotal = 3
    expected.secretsScanned = 3
    expected.matches = 2
    #expect(r.last == expected)
    #expect(await collect(searcher(), .init(value: "secret"), [vault("a")]).matches.isEmpty)
    #expect(await collect(searcher(), .init(value: "secret", caseSensitive: false), [vault("a")]).matches == ["a/s1"])
}

@Test func containsMode() async {
    let s = searcher()
    #expect(await collect(s, .init(value: "secret", mode: .contains), [vault("a")]).matches == ["a/s2"])
    let insensitive = ValueSearcher.Query(value: "SECRET", mode: .contains, caseSensitive: false)
    #expect(await collect(s, insensitive, [vault("a")]).matches == ["a/s1", "a/s2"])
}

@Test func disabledSkippedUnlessIncluded() async {
    let probe = Probe()
    let s = searcher(probe: probe)
    #expect(await collect(s, .init(value: "Secret"), [vault("a")]).matches == ["a/s1"])
    #expect(probe.calls["s3"] == nil)
    #expect(await collect(s, .init(value: "Secret", includeDisabled: true), [vault("a")]).matches == ["a/s1", "a/s3"])
}

@Test func emptyQueryScansNothing() async {
    let probe = Probe()
    let r = await collect(searcher(probe: probe), .init(value: ""), [vault("a")])
    #expect(r.matches.isEmpty && r.last == nil && probe.calls.isEmpty)
}

@Test func constantTimeEquality() {
    typealias Matcher = ValueSearcher.Matcher
    #expect(Matcher.constantTimeEquals(Array("abc".utf8), Array("abc".utf8)))
    #expect(!Matcher.constantTimeEquals(Array("abc".utf8), Array("abd".utf8)))
    #expect(!Matcher.constantTimeEquals(Array("abc".utf8), Array("abcd".utf8)))
    #expect(!Matcher.constantTimeEquals(Array("abc".utf8), Array("ab".utf8)))
    #expect(!Matcher.constantTimeEquals(Array("a".utf8), []))
}

@Test func inaccessibleVaultsSkipped() async {
    let firewall = AzureErrorBody(code: "Forbidden", message: "nope", innerCode: "ForbiddenByFirewall")
    let s = ValueSearcher(
        maxRetries: 0,
        lister: { v in
            switch v.name {
            case "fw": throw AzureAPIError.forbidden(firewall)
            case "denied": throw AzureAPIError.forbidden(nil)
            case "net": throw AzureAPIError.network(.cannotFindHost)
            default: return [.init(name: "x"), .init(name: "y")]
            }
        },
        fetcher: { v, _ in
            if v.name == "listonly" { throw AzureAPIError.forbidden(nil) }
            return "Secret"
        })
    let r = await collect(s, .init(value: "Secret"), ["fw", "denied", "net", "listonly", "ok"].map(vault))
    #expect(r.skipped == ["fw": .firewall, "denied": .forbidden, "net": .network, "listonly": .forbidden])
    #expect(r.matches == ["ok/x", "ok/y"])
    #expect(r.last?.vaultsScanned == 5 && r.last?.secretsTotal == 2)
}

@Test func retriesThrottledReads() async {
    let probe = Probe()
    let s = ValueSearcher(
        maxRetries: 3, sleep: { d in probe.lock.withLock { probe.sleeps.append(d) } },
        lister: { _ in [.init(name: "x")] },
        fetcher: { _, name in
            defer { probe.leave() }
            if probe.enter(name) < 3 { throw AzureAPIError.throttled(retryAfter: nil, nil) }
            return "Secret"
        })
    let r = await collect(s, .init(value: "Secret"), [vault("a")])
    #expect(r.matches == ["a/x"])
    #expect(probe.calls["x"] == 3 && probe.sleeps.count == 2)
}

@Test func failedReadsCounted() async {
    let s = ValueSearcher(
        maxRetries: 0, lister: { _ in [.init(name: "x"), .init(name: "y")] },
        fetcher: { _, name in
            if name == "x" { throw AzureAPIError.http(status: 500, nil) }
            return "Secret"
        })
    let r = await collect(s, .init(value: "Secret"), [vault("a")])
    #expect(r.matches == ["a/y"] && r.last?.secretsFailed == 1 && r.skipped.isEmpty)
}

@Test func concurrencyIsBounded() async {
    let probe = Probe()
    let names = (0..<30).map { "s\($0)" }
    let s = ValueSearcher(
        concurrency: 3, lister: { _ in names.map { .init(name: $0) } },
        fetcher: { _, name in
            _ = probe.enter(name)
            defer { probe.leave() }
            try await Task.sleep(for: .milliseconds(5))
            return name
        })
    let r = await collect(s, .init(value: "s7"), [vault("a")])
    #expect(r.matches == ["a/s7"])
    #expect(probe.peak <= 3 && probe.peak > 1)
}

@Test func cancellationStopsScan() async {
    let probe = Probe()
    let s = ValueSearcher(
        concurrency: 1, lister: { _ in (0..<1000).map { .init(name: "s\($0)") } },
        fetcher: { _, name in
            _ = probe.enter(name)
            defer { probe.leave() }
            try await Task.sleep(for: .milliseconds(2))
            return "Secret"
        })
    let task = Task {
        var matches = 0
        for await e in s.search(.init(value: "Secret"), in: [vault("a")]) {
            if case .match = e { matches += 1 }
        }
        return matches
    }
    try? await Task.sleep(for: .milliseconds(50))
    task.cancel()
    let seen = await task.value
    try? await Task.sleep(for: .milliseconds(50))
    let calls = probe.lock.withLock { probe.calls.count }
    #expect(seen < 1000 && calls < 1000)
}
