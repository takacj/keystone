import AzureAuth
import AzureCore
import Foundation
import Persistence

/// Mock Azure environment used by `-UITestMode` (XCUITest smoke test) and by performance tests.
/// Nothing here touches `az`, the network, the real profile directory or the real context store.
enum UITestSupport {
    static let argument = "-UITestMode"
    static let tenantID = "11111111-1111-1111-1111-111111111111"
    static let subscriptionID = "22222222-2222-2222-2222-222222222222"
    static let accountID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    static let prodVaultName = "kv-prod-weu"
    static var vaultNames: [String] {
        if isDemo { return DemoData.vaultNames }
        return ["kv-dev", "kv-staging"] + (hasFlag("-UITestProd") ? [prodVaultName] : [])
    }
    static let secretValuePrefix = "s3cr3t-"
    /// Current value shared by `sharedValueNames`, so "Search by value" has duplicates to find.
    static let sharedValue = "s3cr3t-shared-connection-string"
    static let sharedValueNames: Set<String> = ["api-key", "svc-0005", "svc-0010"]

    static func hasFlag(_ flag: String) -> Bool { ProcessInfo.processInfo.arguments.contains(flag) }

    static var isActive: Bool { ProcessInfo.processInfo.arguments.contains(argument) }

    /// `-UITestDemo`: realistic-looking names and values, used for README screenshots.
    static var isDemo: Bool { hasFlag("-UITestDemo") }

    /// Fresh per-launch state directory, so runs never share favorites/recents.
    static let stateDirectory: URL = {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("keystone-uitest", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static var contextStore: ContextStateStore {
        ContextStateStore(fileURL: stateDirectory.appendingPathComponent("context.json"))
    }

    static var account: AccountProfile {
        AccountProfile(
            id: accountID, displayName: isDemo ? "Contoso" : "Test Account",
            upn: isDemo ? "alex@contoso.example" : "tester@example.com", homeTenantId: tenantID,
            profileDir: stateDirectory.appendingPathComponent("profile", isDirectory: true))
    }

    /// Number of secrets per vault, overridable with `-UITestSecretCount N`.
    static var secretCount: Int {
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-UITestSecretCount"), i + 1 < args.count, let n = Int(args[i + 1]) { return n }
        return 40
    }
}

/// Returns a fixed token without any process or network work.
struct MockTokenProvider: TokenProvider {
    func token(tenant: String, resource: AzureResource) async throws -> AccessToken {
        AccessToken(value: "mock-token", expiresOn: Date().addingTimeInterval(3600))
    }
    func invalidate(tenant: String, resource: AzureResource) async {}
}

/// Serves canned tenants / subscriptions / vaults / secrets JSON for ARM and Key Vault hosts.
struct MockAzureTransport: HTTPTransport {
    var vaultNames: [String] = UITestSupport.vaultNames
    var secretCount = 40
    var pageSize = 25
    var demo = UITestSupport.isDemo

    /// Secret names of every vault: a few well-known ones followed by `svc-0001…`.
    var secretNames: [String] {
        if demo { return DemoData.secrets.map(\.name) }
        let known = ["db-password", "api-key", "jwt-signing-key"]
        return Array((known + (0..<max(secretCount, 0)).map { String(format: "svc-%04d", $0) }).prefix(secretCount))
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url else { throw URLError(.badURL) }
        let json: Any
        if url.host == "management.azure.com" {
            json = arm(url)
        } else if let host = url.host, host.hasSuffix(".vault.azure.net") {
            json = vault(url)
        } else {
            return (Data(), response(url, status: 404))
        }
        return (try JSONSerialization.data(withJSONObject: json), response(url, status: 200))
    }

    private func response(_ url: URL, status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    // MARK: ARM

    private func vaultResource(_ name: String) -> [String: Any] {
        [
            "id":
                "/subscriptions/\(UITestSupport.subscriptionID)/resourceGroups/rg-test/providers/Microsoft.KeyVault/vaults/\(name)",
            "name": name, "location": "westeurope",
            "properties": [
                "vaultUri": "https://\(name).vault.azure.net/", "tenantId": UITestSupport.tenantID,
                "enableRbacAuthorization": name == vaultNames.first,
            ],
        ]
    }

    private func arm(_ url: URL) -> Any {
        let path = url.path.lowercased()
        if path == "/tenants" {
            return [
                "value": [
                    ["tenantId": UITestSupport.tenantID, "displayName": "Contoso", "defaultDomain": "contoso.example"]
                ]
            ]
        }
        if path == "/subscriptions" {
            return [
                "value": [
                    [
                        "subscriptionId": UITestSupport.subscriptionID,
                        "displayName": demo ? "Contoso Payments" : "Test Subscription",
                        "state": "Enabled", "tenantId": UITestSupport.tenantID,
                    ]
                ]
            ]
        }
        if path.hasSuffix("/microsoft.keyvault/vaults") { return ["value": vaultNames.map(vaultResource)] }
        if path.hasSuffix("/resources") { return ["data": vaultNames.map(vaultResource), "count": vaultNames.count] }
        return ["value": []]
    }

    // MARK: Key Vault

    private func vault(_ url: URL) -> Any {
        let parts = url.path.split(separator: "/").map(String.init)
        let base = "https://\(url.host ?? "")"
        let stamp = Int(Date().timeIntervalSince1970) - 86_400
        func item(_ name: String) -> [String: Any] {
            if demo, let secret = DemoData.secrets.first(where: { $0.name == name }) {
                return DemoData.item(secret, base: base, stamp: stamp)
            }
            var attributes: [String: Any] = ["enabled": true, "created": stamp, "updated": stamp]
            var contentType = "text/plain"
            switch name {
            case "svc-0001": attributes["exp"] = stamp + 10 * 86_400
            case "svc-0002": attributes["enabled"] = false
            case "svc-0003": attributes["exp"] = stamp - 86_400
            case "svc-0004": contentType = "application/json"
            default: break
            }
            return [
                "id": "\(base)/secrets/\(name)",
                "attributes": attributes,
                "tags": name.hasPrefix("svc-") ? ["app": "svc"] : [:],
                "contentType": contentType,
            ]
        }
        switch parts.count {
        case 1 where parts[0] == "secrets":
            let names = secretNames
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let offset = items.first { $0.name == "$skiptoken" }?.value.flatMap(Int.init) ?? 0
            let end = min(offset + pageSize, names.count)
            var page: [String: Any] = ["value": names[min(offset, end)..<end].map(item)]
            if end < names.count {
                page["nextLink"] =
                    "\(base)/secrets?api-version=\(items.first { $0.name == "api-version" }?.value ?? "7.5")&$skiptoken=\(end)"
            }
            return page
        case 2 where parts[0] == "secrets":
            var bundle = item(parts[1])
            bundle["value"] =
                demo
                ? DemoData.value(parts[1])
                : UITestSupport.sharedValueNames.contains(parts[1])
                    ? UITestSupport.sharedValue : UITestSupport.secretValuePrefix + parts[1]
            bundle["id"] = "\(base)/secrets/\(parts[1])/v1"
            return bundle
        case 3 where parts[0] == "secrets" && parts[2] == "versions":
            // v1 = current, v0 = one day older.
            return [
                "value": [("v1", stamp), ("v0", stamp - 86_400)].map { version, created in
                    [
                        "id": "\(base)/secrets/\(parts[1])/\(version)",
                        "attributes": ["enabled": true, "created": created, "updated": created],
                    ] as [String: Any]
                }
            ]
        case 3 where parts[0] == "secrets":
            var bundle = item(parts[1])
            bundle["value"] =
                demo
                ? DemoData.value(parts[2] == "v1" ? parts[1] : parts[1] + "-" + parts[2])
                : UITestSupport.secretValuePrefix + parts[1] + (parts[2] == "v1" ? "" : "-" + parts[2])
            bundle["id"] = "\(base)/secrets/\(parts[1])/\(parts[2])"
            return bundle
        default:
            return ["value": []]
        }
    }
}

/// Fake but plausible vaults and secrets for `-UITestDemo` (README screenshots).
enum DemoData {
    struct Secret {
        enum State { case normal, expiring, expired, disabled }
        var name: String
        var team: String
        var contentType = "text/plain"
        var state = State.normal
    }

    static let vaultNames = [
        "kv-payments-dev", "kv-payments-staging", "kv-payments-prod", "kv-platform-shared", "kv-identity-dev",
    ]

    /// Secrets holding the same current value, so "Search by value" has duplicates to find.
    static let sharedValueNames: Set<String> = ["sendgrid-api-key", "smtp-password"]

    static let secrets: [Secret] = [
        Secret(name: "acr-pull-password", team: "platform"),
        Secret(name: "aks-kubeconfig", team: "platform", contentType: "application/yaml"),
        Secret(name: "app-insights-connection-string", team: "platform"),
        Secret(name: "cosmos-primary-key", team: "payments"),
        Secret(name: "datadog-api-key", team: "platform", state: .expiring),
        Secret(name: "encryption-master-key", team: "security"),
        Secret(name: "github-deploy-token", team: "platform", state: .expired),
        Secret(name: "jwt-signing-key", team: "identity"),
        Secret(name: "legacy-ftp-password", team: "payments", state: .disabled),
        Secret(name: "oauth-client-secret", team: "identity", contentType: "application/json"),
        Secret(name: "openai-api-key", team: "payments"),
        Secret(name: "pagerduty-routing-key", team: "platform"),
        Secret(name: "redis-connection-string", team: "payments"),
        Secret(name: "search-admin-key", team: "payments"),
        Secret(name: "sendgrid-api-key", team: "payments"),
        Secret(name: "service-bus-connection-string", team: "payments"),
        Secret(name: "slack-bot-token", team: "platform", state: .expiring),
        Secret(name: "smtp-password", team: "payments"),
        Secret(name: "sql-admin-password", team: "payments"),
        Secret(name: "storage-account-key", team: "payments"),
        Secret(name: "stripe-secret-key", team: "payments", state: .expiring),
        Secret(name: "stripe-webhook-secret", team: "payments"),
        Secret(name: "terraform-sp-client-secret", team: "platform"),
        Secret(name: "tls-certificate-password", team: "security"),
    ]

    static func item(_ secret: Secret, base: String, stamp: Int) -> [String: Any] {
        let age = (secrets.firstIndex { $0.name == secret.name } ?? 0) * 7 % 90
        let updated = stamp - age * 86_400
        var attributes: [String: Any] = ["enabled": true, "created": updated - 30 * 86_400, "updated": updated]
        switch secret.state {
        case .normal: break
        case .expiring: attributes["exp"] = stamp + 12 * 86_400
        case .expired: attributes["exp"] = stamp - 3 * 86_400
        case .disabled: attributes["enabled"] = false
        }
        return [
            "id": "\(base)/secrets/\(secret.name)",
            "attributes": attributes,
            "tags": ["team": secret.team],
            "contentType": secret.contentType,
        ]
    }

    /// Deterministic random-looking value derived from the key (FNV-1a seeded generator).
    static func value(_ key: String) -> String {
        let seedKey = sharedValueNames.contains(key) ? "shared" : key
        var state: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in seedKey.utf8 { state = (state ^ UInt64(byte)) &* 0x100_0000_01b3 }
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        return String(
            (0..<40).map { _ in
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                return alphabet[Int((state >> 33) % UInt64(alphabet.count))]
            })
    }
}

extension AppModel {
    /// App model for `-UITestMode`: fixed signed-in account, mock token provider and HTTP transport.
    static func uiTest() -> AppModel {
        let defaults = UserDefaults(suiteName: "com.jtakac.keystone.uitest") ?? .standard
        defaults.removePersistentDomain(forName: "com.jtakac.keystone.uitest")
        return AppModel(
            defaults: defaults, mock: (MockTokenProvider(), MockAzureTransport(secretCount: UITestSupport.secretCount)))
    }
}
