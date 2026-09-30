import AzureCLI
import AzureCore
import Foundation
import Testing

@testable import AzureAuth

private actor FakeRunner: CLIRunning {
    private(set) var calls: [[String]] = []
    private(set) var dirs: [URL?] = []
    var delay: Duration = .zero
    var failure: (any Error)?
    var expiresIn: TimeInterval = 3600
    private var counter = 0

    func configure(delay: Duration? = nil, failure: (any Error)?? = nil, expiresIn: TimeInterval? = nil) {
        if let delay { self.delay = delay }
        if let failure { self.failure = failure }
        if let expiresIn { self.expiresIn = expiresIn }
    }

    func run(_ args: [String], profileDir: URL?, timeout: Duration) async throws -> CLIResult {
        calls.append(args)
        dirs.append(profileDir)
        counter += 1
        let n = counter
        if delay > .zero { try await Task.sleep(for: delay) }
        if let failure { throw failure }
        let exp = Int(Date().timeIntervalSince1970 + expiresIn)
        return CLIResult(
            exitCode: 0, stdout: #"{"accessToken":"tok\#(n)","expires_on":\#(exp),"tenant":"t"}"#, stderr: "")
    }
}

@Suite struct AzureCLITokenProviderTests {
    let dir = URL(fileURLWithPath: "/tmp/profile")

    @Test func buildsCommandAndParses() async throws {
        let r = FakeRunner()
        let p = AzureCLITokenProvider(runner: r, profileDir: dir)
        let t = try await p.token(tenant: "T1", resource: .vault)
        #expect(t.value == "tok1")
        #expect(
            await r.calls == [
                [
                    "account", "get-access-token", "--tenant", "T1", "--resource", "https://vault.azure.net", "-o",
                    "json",
                ]
            ])
        #expect(await r.dirs == [dir])
    }

    @Test func cachesPerKey() async throws {
        let r = FakeRunner()
        let p = AzureCLITokenProvider(runner: r, profileDir: dir)
        _ = try await p.token(tenant: "T1", resource: .arm)
        _ = try await p.token(tenant: "T1", resource: .arm)
        #expect(await r.calls.count == 1)
        _ = try await p.token(tenant: "T1", resource: .vault)
        _ = try await p.token(tenant: "T2", resource: .arm)
        #expect(await r.calls.count == 3)
    }

    @Test func refreshesWithinMargin() async throws {
        let r = FakeRunner()
        await r.configure(expiresIn: 200)  // < 5 min margin
        let p = AzureCLITokenProvider(runner: r, profileDir: dir)
        _ = try await p.token(tenant: "T", resource: .arm)
        _ = try await p.token(tenant: "T", resource: .arm)
        #expect(await r.calls.count == 2)
    }

    @Test func clockAdvanceTriggersRefresh() async throws {
        final class Clock: @unchecked Sendable {
            let lock = NSLock()
            var t = Date()
            func get() -> Date { lock.withLock { t } }
            func advance(_ s: TimeInterval) { lock.withLock { t = t.addingTimeInterval(s) } }
        }
        let clock = Clock()
        let r = FakeRunner()
        let p = AzureCLITokenProvider(runner: r, profileDir: dir, now: { clock.get() })
        _ = try await p.token(tenant: "T", resource: .arm)
        clock.advance(3600 - 301)
        _ = try await p.token(tenant: "T", resource: .arm)
        #expect(await r.calls.count == 1)
        clock.advance(2)
        _ = try await p.token(tenant: "T", resource: .arm)
        #expect(await r.calls.count == 2)
    }

    @Test func dedupesInFlight() async throws {
        let r = FakeRunner()
        await r.configure(delay: .milliseconds(150))
        let p = AzureCLITokenProvider(runner: r, profileDir: dir)
        let tokens = try await withThrowingTaskGroup(of: String.self) { g in
            for _ in 0..<10 { g.addTask { try await p.token(tenant: "T", resource: .arm).value } }
            var out: [String] = []
            for try await v in g { out.append(v) }
            return out
        }
        #expect(await r.calls.count == 1)
        #expect(Set(tokens) == ["tok1"])
    }

    @Test func invalidateForcesRefetch() async throws {
        let r = FakeRunner()
        let p = AzureCLITokenProvider(runner: r, profileDir: dir)
        let a = try await p.token(tenant: "T", resource: .arm)
        await p.invalidate(tenant: "T", resource: .arm)
        let b = try await p.token(tenant: "T", resource: .arm)
        #expect(a.value == "tok1" && b.value == "tok2")
    }

    @Test func failureNotCachedAndPropagates() async throws {
        let r = FakeRunner()
        await r.configure(failure: AzureCLIError.loginRequired(message: "x"))
        let p = AzureCLITokenProvider(runner: r, profileDir: dir)
        await #expect(throws: AzureCLIError.self) { try await p.token(tenant: "T", resource: .arm) }
        await r.configure(failure: .some(nil))
        let t = try await p.token(tenant: "T", resource: .arm)
        #expect(t.value == "tok2")
    }

    @Test func parseVariants() throws {
        let s = try AzureCLITokenProvider.parse(#"{"accessToken":"a","expires_on":"1900000000"}"#)
        #expect(s.expiresOn == Date(timeIntervalSince1970: 1_900_000_000))
        let old = try AzureCLITokenProvider.parse(#"{"accessToken":"a","expiresOn":"2030-01-01 12:00:00.000000"}"#)
        #expect(old.expiresOn > Date())
        #expect(throws: AzureCLITokenError.self) { try AzureCLITokenProvider.parse("{}") }
        #expect(throws: AzureCLITokenError.self) { try AzureCLITokenProvider.parse(#"{"accessToken":"a"}"#) }
    }
}
