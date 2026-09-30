import AzureCLI
import Foundation
import Testing

@testable import AzureAuth

private actor FakeRunner: CLIRunning {
    struct Call: Equatable {
        let args: [String]
        let dir: URL?
        let timeout: Duration
    }
    private(set) var calls: [Call] = []
    var failLogin = false
    var showJSON = #"{"homeTenantId":"tenant-home","tenantId":"tenant-x","user":{"name":"me@contoso.com"}}"#

    func setFailLogin(_ v: Bool) { failLogin = v }

    func run(_ args: [String], profileDir: URL?, timeout: Duration) async throws -> CLIResult {
        calls.append(Call(args: args, dir: profileDir, timeout: timeout))
        if args.first == "login" && failLogin { throw AzureCLIError.commandFailed(exitCode: 1, stderr: "nope") }
        if args.first == "account" && args.dropFirst().first == "show" {
            return CLIResult(exitCode: 0, stdout: showJSON, stderr: "")
        }
        return CLIResult(exitCode: 0, stdout: "", stderr: "")
    }
}

private func tempRoot() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("secreter-test-\(UUID().uuidString)")
}

@Test func addAccountRunsLoginAndPersists() async throws {
    let root = tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let runner = FakeRunner()
    let store = ProfileStore(rootDirectory: root, runner: runner)
    let p = try await store.addAccount(options: .init(useDeviceCode: true, tenant: "t1"))
    #expect(p.upn == "me@contoso.com")
    #expect(p.displayName == "me@contoso.com")
    #expect(p.homeTenantId == "tenant-home")
    #expect(p.profileDir == root.appendingPathComponent("profiles/\(p.id.uuidString)"))
    #expect(FileManager.default.fileExists(atPath: p.profileDir.path))
    let calls = await runner.calls
    #expect(calls[0].args == ["login", "-o", "json", "--use-device-code", "--tenant", "t1"])
    #expect(calls[0].timeout == CLIRunner.loginTimeout)
    #expect(calls[0].dir == p.profileDir)
    #expect(calls[1].args == ["account", "show", "-o", "json"])
    // new store instance reads accounts.json
    let again = ProfileStore(rootDirectory: root, runner: runner)
    #expect(try await again.accounts() == [p])
}

@Test func addAccountFailureCleansUp() async throws {
    let root = tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let runner = FakeRunner()
    await runner.setFailLogin(true)
    let store = ProfileStore(rootDirectory: root, runner: runner)
    await #expect(throws: AzureCLIError.self) { try await store.addAccount() }
    #expect(try await store.accounts().isEmpty)
    let dirs =
        (try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("profiles").path)) ?? []
    #expect(dirs.isEmpty)
}

@Test func reLoginUsesTenantInSameProfile() async throws {
    let root = tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let runner = FakeRunner()
    let store = ProfileStore(rootDirectory: root, runner: runner)
    let p = try await store.addAccount(displayName: "  Work ")
    #expect(p.displayName == "Work")
    _ = try await store.reLogin(id: p.id, tenant: "tenant-2")
    let calls = await runner.calls
    let login = calls.last { $0.args.first == "login" }
    #expect(login?.args == ["login", "-o", "json", "--tenant", "tenant-2"])
    #expect(login?.dir == p.profileDir)
}

@Test func removeLogsOutClearsAndDeletes() async throws {
    let root = tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let runner = FakeRunner()
    let store = ProfileStore(rootDirectory: root, runner: runner)
    let p = try await store.addAccount()
    try await store.removeAccount(id: p.id)
    let calls = await runner.calls.map(\.args)
    #expect(calls.contains(["logout"]))
    #expect(calls.contains(["account", "clear"]))
    #expect(!FileManager.default.fileExists(atPath: p.profileDir.path))
    #expect(try await store.accounts().isEmpty)
    await #expect(throws: ProfileStoreError.accountNotFound(p.id)) { try await store.removeAccount(id: p.id) }
}

@Test func accountInfoParsing() throws {
    #expect(
        try AzureAccountInfo.parse(#"{"tenantId":"t","user":{"name":"a@b"}}"#) == .init(upn: "a@b", homeTenantId: "t"))
    #expect(throws: ProfileStoreError.self) { try AzureAccountInfo.parse("{}") }
    #expect(throws: ProfileStoreError.self) { try AzureAccountInfo.parse("junk") }
}
