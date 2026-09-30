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
        ["kv-dev", "kv-staging"] + (hasFlag("-UITestProd") ? [prodVaultName] : [])
    }
    static let secretValuePrefix = "s3cr3t-"

    static func hasFlag(_ flag: String) -> Bool { ProcessInfo.processInfo.arguments.contains(flag) }

    static var isActive: Bool { ProcessInfo.processInfo.arguments.contains(argument) }

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
            id: accountID, displayName: "Test Account", upn: "tester@example.com", homeTenantId: tenantID,
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

    /// Secret names of every vault: a few well-known ones followed by `svc-0001…`.
    var secretNames: [String] {
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
                        "subscriptionId": UITestSupport.subscriptionID, "displayName": "Test Subscription",
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
            bundle["value"] = UITestSupport.secretValuePrefix + parts[1]
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
            bundle["value"] = UITestSupport.secretValuePrefix + parts[1] + (parts[2] == "v1" ? "" : "-" + parts[2])
            bundle["id"] = "\(base)/secrets/\(parts[1])/\(parts[2])"
            return bundle
        default:
            return ["value": []]
        }
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
