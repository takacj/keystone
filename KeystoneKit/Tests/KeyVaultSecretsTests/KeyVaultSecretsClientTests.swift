import AzureCore
import Foundation
import Testing

@testable import KeyVaultSecrets

private final class State: @unchecked Sendable {
    let lock = NSLock()
    var responses: [(Int, String)]
    var requests: [URLRequest] = []
    var inFlight = 0
    init(_ r: [(Int, String)]) { responses = r }
}

private struct Transport: HTTPTransport {
    let s: State
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (code, body) = s.lock.withLock {
            s.requests.append(request)
            return s.responses.removeFirst()
        }
        return (
            Data(body.utf8),
            HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!
        )
    }
}

private struct Tokens: TokenProvider {
    func token(tenant: String, resource: AzureResource) async throws -> AccessToken {
        AccessToken(value: "t", expiresOn: .distantFuture)
    }
    func invalidate(tenant: String, resource: AzureResource) async {}
}

private func client(_ s: State) -> KeyVaultSecretsClient {
    KeyVaultSecretsClient(
        vaultURI: URL(string: "https://v.vault.azure.net")!,
        http: AzureHTTPClient(
            tokenProvider: Tokens(), tenant: "t", resource: .vault, transport: Transport(s: s)))
}

private let bundle = """
    {"id":"https://v.vault.azure.net/secrets/my-secret/abc123","value":"s3cret","contentType":"text/plain",
     "attributes":{"enabled":true,"exp":1800000000,"created":1700000000,"updated":1700000100,"recoveryLevel":"Recoverable+Purgeable"},
     "tags":{"env":"prod"}}
    """

private func call(_ s: State, _ i: Int = 0) -> (String, String, String?) {
    let r = s.requests[i]
    return (r.httpMethod!, r.url!.absoluteString, r.httpBody.flatMap { String(data: $0, encoding: .utf8) })
}

@Test func listFollowsNextLink() async throws {
    let s = State([
        (
            200,
            #"{"value":[{"id":"https://v.vault.azure.net/secrets/a","attributes":{"enabled":true}}],"nextLink":"https://v.vault.azure.net/secrets?api-version=7.5&$skiptoken=x"}"#
        ),
        (200, #"{"value":[{"id":"https://v.vault.azure.net/secrets/b"}]}"#),
    ])
    var names: [String] = []
    for try await page in client(s).listSecrets() { names += page.map(\.name) }
    #expect(names == ["a", "b"])
    #expect(call(s).1 == "https://v.vault.azure.net/secrets?maxresults=25&api-version=7.5")
    #expect(call(s, 1).1.contains("skiptoken=x"))
}

@Test func getCurrentAndVersion() async throws {
    let s = State([(200, bundle), (200, bundle)])
    let c = client(s)
    let b = try await c.getSecret(name: "my-secret")
    #expect(b.value == "s3cret")
    #expect(b.name == "my-secret" && b.version == "abc123")
    #expect(b.attributes?.expires == Date(timeIntervalSince1970: 1_800_000_000))
    _ = try await c.getSecret(name: "my-secret", version: "abc123")
    #expect(call(s).1 == "https://v.vault.azure.net/secrets/my-secret?api-version=7.5")
    #expect(call(s, 1).1 == "https://v.vault.azure.net/secrets/my-secret/abc123?api-version=7.5")
    #expect(!"\(b)".contains("s3cret") && !"\(String(reflecting: b))".contains("s3cret"))
}

@Test func versionsList() async throws {
    let s = State([(200, #"{"value":[{"id":"https://v.vault.azure.net/secrets/n/v1"}]}"#)])
    var out: [SecretItem] = []
    for try await p in client(s).listVersions(name: "n") { out += p }
    #expect(out.first?.version == "v1")
    #expect(call(s).1 == "https://v.vault.azure.net/secrets/n/versions?maxresults=25&api-version=7.5")
}

@Test func setSendsBody() async throws {
    let s = State([(200, bundle)])
    _ = try await client(s).setSecret(
        name: "n", SetSecretRequest(value: "v", contentType: "text/plain", tags: ["a": "b"]))
    let (m, u, body) = call(s)
    #expect(m == "PUT" && u == "https://v.vault.azure.net/secrets/n?api-version=7.5")
    let json = try JSONSerialization.jsonObject(with: Data(body!.utf8)) as! [String: Any]
    #expect(json["value"] as? String == "v" && json["contentType"] as? String == "text/plain")
    #expect((json["tags"] as? [String: String]) == ["a": "b"])
}

@Test func patchEncodesEpochDates() async throws {
    let s = State([(200, bundle)])
    let attrs = SecretAttributes(enabled: false, expires: Date(timeIntervalSince1970: 1_900_000_000))
    _ = try await client(s).updateSecret(name: "n", version: "v1", UpdateSecretRequest(attributes: attrs))
    let (m, u, body) = call(s)
    #expect(m == "PATCH" && u == "https://v.vault.azure.net/secrets/n/v1?api-version=7.5")
    let json = try JSONSerialization.jsonObject(with: Data(body!.utf8)) as! [String: Any]
    let a = json["attributes"] as! [String: Any]
    #expect(a["enabled"] as? Bool == false && a["exp"] as? Int == 1_900_000_000)
    #expect(json["contentType"] == nil)
}

@Test func deleteRecoverPurgeAndDeletedList() async throws {
    let s = State([
        (
            200,
            #"{"id":"https://v.vault.azure.net/secrets/n/v1","value":"x","recoveryId":"https://v.vault.azure.net/deletedsecrets/n","deletedDate":1700000000,"scheduledPurgeDate":1707776000}"#
        ),
        (200, #"{"value":[{"id":"https://v.vault.azure.net/deletedsecrets/n","deletedDate":1700000000}]}"#),
        (200, bundle),
        (204, ""),
    ])
    let c = client(s)
    let d = try await c.deleteSecret(name: "n")
    #expect(d.deletedDate == Date(timeIntervalSince1970: 1_700_000_000))
    var del: [DeletedSecretItem] = []
    for try await p in c.listDeletedSecrets() { del += p }
    #expect(del.first?.name == "n")
    _ = try await c.recoverDeletedSecret(name: "n")
    try await c.purgeDeletedSecret(name: "n")
    #expect(call(s, 0).0 == "DELETE" && call(s, 0).1 == "https://v.vault.azure.net/secrets/n?api-version=7.5")
    #expect(call(s, 1).1 == "https://v.vault.azure.net/deletedsecrets?maxresults=25&api-version=7.5")
    #expect(call(s, 2).0 == "POST" && call(s, 2).1.contains("/deletedsecrets/n/recover?"))
    #expect(call(s, 3).0 == "DELETE" && call(s, 3).1.contains("/deletedsecrets/n?"))
}

@Test func conflictOnSetMapsTo409() async throws {
    let s = State([(409, #"{"error":{"code":"Conflict","message":"deleted"}}"#)])
    await #expect(throws: AzureAPIError.self) {
        try await client(s).setSecret(name: "n", SetSecretRequest(value: "v"))
    }
}

@Test func invalidNameRejected() async throws {
    let s = State([])
    await #expect(throws: AzureAPIError.self) { try await client(s).getSecret(name: "") }
}

@Test func bulkLimitsConcurrencyAndKeepsOrder() async {
    let s = State([])
    let res = await KeyVaultSecretsClient.bulk(Array(0..<12), limit: 4) { (i: Int) -> Int in
        let cur = s.lock.withLock {
            s.inFlight += 1
            return s.inFlight
        }
        try await Task.sleep(for: .milliseconds(20))
        s.lock.withLock { s.inFlight -= 1 }
        if i == 5 { throw AzureAPIError.notFound(nil) }
        return cur
    }
    #expect(res.map(\.input) == Array(0..<12))
    let peak = res.compactMap { try? $0.result.get() }.max() ?? 0
    #expect(peak <= 4 && peak >= 2)
    if case .failure = res[5].result {} else { Issue.record("expected failure at 5") }
}
