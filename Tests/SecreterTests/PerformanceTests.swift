import AzureAuth
import AzureCLI
import AzureCore
import Foundation
import KeyVaultSecrets
import Testing

@testable import Secreter

/// Performance targets over mock data (no network, no `az`).
@MainActor
@Suite struct PerformanceTests {
    private static func vaultClient(count: Int) -> KeyVaultSecretsClient {
        let http = AzureHTTPClient(
            tokenProvider: MockTokenProvider(), tenant: UITestSupport.tenantID, resource: .vault,
            transport: MockAzureTransport(secretCount: count))
        return KeyVaultSecretsClient(vaultURI: URL(string: "https://kv-dev.vault.azure.net/")!, http: http)
    }

    @Test func listing1000SecretsUnder3s() async throws {
        let client = Self.vaultClient(count: 1000)
        let clock = ContinuousClock()
        var items: [SecretItem] = []
        let elapsed = try await clock.measure {
            for try await page in client.listSecrets(maxResults: 25) { items += page }
        }
        #expect(items.count == 1000)
        #expect(elapsed < .seconds(3), "listing took \(elapsed)")
    }

    @Test func filterKeystrokeUnder16ms() async throws {
        let client = Self.vaultClient(count: 1000)
        var items: [SecretItem] = []
        for try await page in client.listSecrets(maxResults: 25) { items += page }
        let model = SecretsModel()
        model.setRowsForTesting(items.map(SecretRow.init))
        // Worst case per keystroke: average over the keystrokes of a typical query.
        let clock = ContinuousClock()
        let query = "svc0500"
        let elapsed = clock.measure {
            for end in 1...query.count { model.filterText = String(query.prefix(end)) }
        }
        let perKeystroke = elapsed / query.count
        #expect(model.visible.map(\.name) == ["svc-0500"])
        #expect(perKeystroke < .milliseconds(16), "filter took \(perKeystroke) per keystroke")
    }

    @Test func cachedTokenUnder1ms() async throws {
        let provider = AzureCLITokenProvider(runner: FastRunner(), profileDir: URL(fileURLWithPath: "/tmp/profile"))
        _ = try await provider.token(tenant: "t", resource: .vault)  // cold: fills the cache
        let clock = ContinuousClock()
        let elapsed = try await clock.measure {
            _ = try await provider.token(tenant: "t", resource: .vault)
        }
        #expect(elapsed < .milliseconds(1), "cached token took \(elapsed)")
    }
}

private struct FastRunner: CLIRunning {
    func run(_ arguments: [String], profileDir: URL?, timeout: Duration) async throws -> CLIResult {
        let exp = Int(Date().timeIntervalSince1970 + 3600)
        return CLIResult(exitCode: 0, stdout: #"{"accessToken":"tok","expires_on":\#(exp),"tenant":"t"}"#, stderr: "")
    }
}
