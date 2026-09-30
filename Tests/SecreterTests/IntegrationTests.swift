import AzureAuth
import AzureCLI
import AzureCore
import Foundation
import KeyVaultSecrets
import Testing

/// Opt-in tests against real Azure test vaults. Skipped unless the env vars are set:
/// - `SECRETER_IT_PROFILE_DIR`: `AZURE_CONFIG_DIR` of a logged-in `az` profile
/// - `SECRETER_IT_TENANT`: tenant id owning the vaults
/// - `SECRETER_IT_VAULT_RBAC` / `SECRETER_IT_VAULT_POLICY`: vault URIs (`https://name.vault.azure.net`)
/// Run with `make test-integration` (see README.md).
private enum IT {
    static func env(_ key: String) -> String? {
        ProcessInfo.processInfo.environment[key].flatMap { $0.isEmpty ? nil : $0 }
    }
    static var profileConfigured: Bool { env("SECRETER_IT_PROFILE_DIR") != nil && env("SECRETER_IT_TENANT") != nil }
    static var rbacConfigured: Bool { profileConfigured && env("SECRETER_IT_VAULT_RBAC") != nil }
    static var policyConfigured: Bool { profileConfigured && env("SECRETER_IT_VAULT_POLICY") != nil }

    static func provider() async throws -> AzureCLITokenProvider {
        let az = try await AzureLocator().locate(override: nil)
        return AzureCLITokenProvider(
            runner: CLIRunner(executable: az), profileDir: URL(fileURLWithPath: env("SECRETER_IT_PROFILE_DIR")!))
    }

    static func list(vault key: String) async throws -> [SecretItem] {
        let http = AzureHTTPClient(
            tokenProvider: try await provider(), tenant: env("SECRETER_IT_TENANT")!, resource: .vault)
        let client = KeyVaultSecretsClient(vaultURI: URL(string: env(key)!)!, http: http)
        var all: [SecretItem] = []
        for try await page in client.listSecrets() { all += page }
        return all
    }
}

@Suite struct IntegrationTests {
    @Test(.enabled(if: IT.profileConfigured, "set SECRETER_IT_PROFILE_DIR and SECRETER_IT_TENANT"))
    func coldTokenUnder2s() async throws {
        let provider = try await IT.provider()
        let clock = ContinuousClock()
        let elapsed = try await clock.measure {
            _ = try await provider.token(tenant: IT.env("SECRETER_IT_TENANT")!, resource: .vault)
        }
        #expect(elapsed < .seconds(2), "cold token took \(elapsed)")
    }

    @Test(.enabled(if: IT.rbacConfigured, "set SECRETER_IT_VAULT_RBAC"))
    func listsRBACVault() async throws {
        let clock = ContinuousClock()
        var items: [SecretItem] = []
        let elapsed = try await clock.measure { items = try await IT.list(vault: "SECRETER_IT_VAULT_RBAC") }
        #expect(!items.isEmpty)
        #expect(elapsed < .seconds(3) * max(1, Double(items.count) / 1000))
    }

    @Test(.enabled(if: IT.policyConfigured, "set SECRETER_IT_VAULT_POLICY"))
    func listsAccessPolicyVault() async throws {
        #expect(try await !IT.list(vault: "SECRETER_IT_VAULT_POLICY").isEmpty)
    }
}
