import AzureAuth
import AzureCLI
import Foundation
import Testing

@testable import Keystone

private struct FakeRunner: CLIRunning {
    func run(_ arguments: [String], profileDir: URL?, timeout: Duration) async throws -> CLIResult {
        switch arguments.first {
        case "version": return CLIResult(exitCode: 0, stdout: #"{"azure-cli":"2.70.0"}"#, stderr: "")
        case "account":
            return CLIResult(
                exitCode: 0, stdout: #"{"user":{"name":"a@b.com"},"tenantId":"t1","homeTenantId":"t1"}"#, stderr: "")
        default: return CLIResult(exitCode: 0, stdout: "{}", stderr: "")
        }
    }
}

@MainActor
@Suite struct AppModelTests {
    private func makeModel(found: Bool) -> AppModel {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let locator = AzureLocator(
            isExecutable: { _ in found }, shellWhich: { found ? "/fake/az" : nil })
        return AppModel(
            locator: locator, rootDirectory: root, defaults: defaults, runnerFactory: { _ in FakeRunner() })
    }

    @Test func missingAzShowsOnboarding() async {
        let m = makeModel(found: false)
        await m.bootstrap()
        #expect(m.azureStatus == .missing)
        #expect(m.needsOnboarding)
    }

    @Test func addAccountSelectsIt() async throws {
        let m = makeModel(found: true)
        await m.bootstrap()
        #expect(m.azureStatus.isReady && m.accounts.isEmpty && m.needsOnboarding)
        m.addAccount(useDeviceCode: false)
        for _ in 0..<100 where m.accounts.isEmpty || m.isLoggingIn { try await Task.sleep(for: .milliseconds(50)) }
        #expect(m.accounts.count == 1)
        #expect(m.selectedAccount?.upn == "a@b.com")
        #expect(!m.needsOnboarding)
        #expect(m.tokenProvider(for: m.accounts[0]) != nil)
    }
}
