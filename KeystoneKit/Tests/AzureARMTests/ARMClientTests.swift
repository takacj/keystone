import AzureCore
import Foundation
import Testing

@testable import AzureARM

private final class State: @unchecked Sendable {
    let lock = NSLock()
    var responses: [String]
    var requests: [URLRequest] = []
    var tokenTenants: [String] = []
    init(_ r: [String]) { responses = r }
}

private struct Fake: HTTPTransport, TokenProvider {
    let s: State
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let body = s.lock.withLock { () -> String in
            s.requests.append(request)
            return s.responses.removeFirst()
        }
        let r = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (Data(body.utf8), r)
    }
    func token(tenant: String, resource: AzureResource) async throws -> AccessToken {
        s.lock.withLock { s.tokenTenants.append("\(tenant)|\(resource.rawValue)") }
        return AccessToken(value: "tok-\(tenant)", expiresOn: .distantFuture)
    }
    func invalidate(tenant: String, resource: AzureResource) async {}
}

private func make(_ s: State) -> ARMClient {
    let f = Fake(s: s)
    return ARMClient(tokenProvider: f, transport: f)
}

@Test func tenantsUsesHomeTenantToken() async throws {
    let s = State([
        #"{"value":[{"id":"/tenants/t1","tenantId":"t1","displayName":"Contoso","defaultDomain":"contoso.com"},{"tenantId":"t2"}]}"#
    ])
    let t = try await make(s).tenants(homeTenant: "t1")
    #expect(t.map(\.tenantId) == ["t1", "t2"])
    #expect(t[0].displayName == "Contoso")
    #expect(t[1].displayName == nil)
    #expect(s.requests[0].url?.absoluteString == "https://management.azure.com/tenants?api-version=2022-12-01")
    #expect(s.requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer tok-t1")
    #expect(s.tokenTenants == ["t1|https://management.azure.com/"])
}

@Test func subscriptionsPaginateWithTenantToken() async throws {
    let next = "https://management.azure.com/subscriptions?api-version=2022-12-01&$skiptoken=x"
    let s = State([
        #"{"value":[{"subscriptionId":"s1","displayName":"Prod","state":"Enabled","tenantId":"t9"}],"nextLink":"\#(next)"}"#,
        #"{"value":[{"subscriptionId":"s2","displayName":"Dev","state":"Disabled"}]}"#,
    ])
    let subs = try await make(s).subscriptions(tenant: "t9")
    #expect(subs.map(\.subscriptionId) == ["s1", "s2"])
    #expect(subs[0].tenantId == "t9")
    #expect(subs[1].state == "Disabled")
    #expect(s.requests.count == 2)
    #expect(s.requests[1].url?.absoluteString == next)
    #expect(s.requests[1].value(forHTTPHeaderField: "Authorization") == "Bearer tok-t9")
}

@Test func vaultsDecodeProperties() async throws {
    let s = State([
        """
        {"value":[
         {"id":"/subscriptions/sub1/resourceGroups/rg-a/providers/Microsoft.KeyVault/vaults/kv1",
          "name":"kv1","location":"westeurope","type":"Microsoft.KeyVault/vaults",
          "properties":{"vaultUri":"https://kv1.vault.azure.net/","tenantId":"t1",
            "enableRbacAuthorization":true,"enableSoftDelete":true,"enablePurgeProtection":true,
            "softDeleteRetentionInDays":90}},
         {"id":"/subscriptions/sub1/resourcegroups/rg-b/providers/Microsoft.KeyVault/vaults/kv2",
          "name":"kv2","location":"eastus","properties":{"vaultUri":"https://kv2.vault.azure.net/"}}
        ]}
        """
    ])
    let v = try await make(s).vaults(subscriptionId: "sub1", tenant: "t1")
    #expect(
        s.requests[0].url?.absoluteString
            == "https://management.azure.com/subscriptions/sub1/providers/Microsoft.KeyVault/vaults?api-version=2023-07-01"
    )
    #expect(v[0].name == "kv1")
    #expect(v[0].vaultUri.absoluteString == "https://kv1.vault.azure.net/")
    #expect(v[0].resourceGroup == "rg-a")
    #expect(v[0].subscriptionId == "sub1")
    #expect(v[0].location == "westeurope")
    #expect(v[0].enableRbacAuthorization && v[0].enableSoftDelete && v[0].enablePurgeProtection)
    #expect(v[0].softDeleteRetentionInDays == 90)
    // Defaults when properties omitted; resource group matched case-insensitively.
    #expect(v[1].resourceGroup == "rg-b")
    #expect(!v[1].enableRbacAuthorization && v[1].enableSoftDelete && !v[1].enablePurgeProtection)
}

@Test func vaultWithoutVaultUriFails() async {
    let s = State([#"{"value":[{"id":"/subscriptions/s/resourceGroups/r/x/y","name":"n","properties":{}}]}"#])
    await #expect(throws: (any Error).self) {
        _ = try await make(s).vaults(subscriptionId: "s", tenant: "t")
    }
}

@Test func resourceGraphDiscoversVaultsWithSkipToken() async throws {
    let v =
        #"{"id":"/subscriptions/S1/resourceGroups/RG/providers/Microsoft.KeyVault/vaults/kv1","name":"kv1","location":"westeurope","tenantId":"t","properties":{"vaultUri":"https://kv1.vault.azure.net/","enableRbacAuthorization":true}}"#
    let w =
        #"{"id":"/subscriptions/S2/resourceGroups/RG/providers/Microsoft.KeyVault/vaults/kv2","name":"kv2","location":"northeurope","properties":{"vaultUri":"https://kv2.vault.azure.net/"}}"#
    let s = State([
        #"{"totalRecords":2,"count":1,"data":[\#(v)],"$skipToken":"tok1"}"#,
        #"{"totalRecords":2,"count":1,"data":[\#(w)]}"#,
    ])
    let vaults = try await make(s).discoverVaults(tenant: "t9", pageSize: 1)
    #expect(vaults.map(\.name) == ["kv1", "kv2"])
    #expect(vaults[0].subscriptionId == "S1" && vaults[0].enableRbacAuthorization)
    #expect(s.requests.count == 2)
    let r0 = s.requests[0]
    #expect(r0.httpMethod == "POST")
    #expect(
        r0.url?.absoluteString
            == "https://management.azure.com/providers/Microsoft.ResourceGraph/resources?api-version=2022-10-01")
    #expect(r0.value(forHTTPHeaderField: "Authorization") == "Bearer tok-t9")
    let b0 = try JSONSerialization.jsonObject(with: r0.httpBody!) as! [String: Any]
    #expect((b0["query"] as! String).contains("microsoft.keyvault/vaults"))
    let o0 = b0["options"] as! [String: Any]
    #expect(o0["$top"] as? Int == 1 && o0["$skipToken"] == nil && o0["resultFormat"] as? String == "objectArray")
    let b1 = try JSONSerialization.jsonObject(with: s.requests[1].httpBody!) as! [String: Any]
    #expect((b1["options"] as! [String: Any])["$skipToken"] as? String == "tok1")
}
