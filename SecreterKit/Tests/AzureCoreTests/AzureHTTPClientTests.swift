import Foundation
import Testing

@testable import AzureCore

private final class State: @unchecked Sendable {
    let lock = NSLock()
    var responses: [(Int, String, [String: String])]
    var requests: [URLRequest] = []
    var sleeps: [TimeInterval] = []
    var invalidations = 0
    var tokenCount = 0
    var networkError: URLError?
    init(_ r: [(Int, String, [String: String])]) { responses = r }
}

private struct FakeTransport: HTTPTransport {
    let s: State
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (code, body, headers) = try s.lock.withLock {
            s.requests.append(request)
            if let e = s.networkError { throw e }
            return s.responses.removeFirst()
        }
        let resp = HTTPURLResponse(
            url: request.url!, statusCode: code, httpVersion: nil, headerFields: headers)!
        return (Data(body.utf8), resp)
    }
}

private struct FakeTokens: TokenProvider {
    let s: State
    func token(tenant: String, resource: AzureResource) async throws -> AccessToken {
        let n = s.lock.withLock {
            s.tokenCount += 1
            return s.tokenCount
        }
        return AccessToken(value: "tok\(n)", expiresOn: .distantFuture)
    }
    func invalidate(tenant: String, resource: AzureResource) async {
        s.lock.withLock { s.invalidations += 1 }
    }
}

private struct Item: Codable, Sendable, Equatable { let id: Int }

private func makeClient(_ s: State) -> AzureHTTPClient {
    AzureHTTPClient(
        tokenProvider: FakeTokens(s: s), tenant: "t", resource: .vault,
        transport: FakeTransport(s: s),
        sleep: { d in s.lock.withLock { s.sleeps.append(d) } },
        jitter: { 1 })
}

private let url = URL(string: "https://v.vault.azure.net/secrets")!

@Test func bearerHeaderAndDecode() async throws {
    let s = State([(200, #"{"id":7}"#, [:])])
    let item: Item = try await makeClient(s).get(url)
    #expect(item == Item(id: 7))
    #expect(s.requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer tok1")
}

@Test func paginationFollowsNextLink() async throws {
    let s = State([
        (200, #"{"value":[{"id":1},{"id":2}],"nextLink":"https://v.vault.azure.net/secrets?p=2"}"#, [:]),
        (200, #"{"value":[{"id":3}]}"#, [:]),
    ])
    var all: [Item] = []
    for try await page in makeClient(s).paginate(url, as: Item.self) { all += page }
    #expect(all.map(\.id) == [1, 2, 3])
    #expect(s.requests[1].url?.query == "p=2")
}

@Test func retriesThrottleWithRetryAfterThenSucceeds() async throws {
    let s = State([
        (429, "", ["Retry-After": "5"]), (503, "", [:]), (200, #"{"id":1}"#, [:]),
    ])
    let _: Item = try await makeClient(s).get(url)
    #expect(s.sleeps.count == 2)
    #expect(s.sleeps[0] == 5)
    #expect(s.sleeps[1] == 1.0)  // base 0.5 * 2^1, jitter 1
}

@Test func givesUpAfterThreeRetries() async {
    let s = State(Array(repeating: (429, "", [:]), count: 4))
    await #expect(throws: AzureAPIError.throttled(retryAfter: nil, nil)) {
        let _: Item = try await makeClient(s).get(url)
    }
    #expect(s.requests.count == 4)
}

@Test func unauthorizedInvalidatesAndRetriesOnce() async throws {
    let s = State([(401, "", [:]), (200, #"{"id":1}"#, [:])])
    let _: Item = try await makeClient(s).get(url)
    #expect(s.invalidations == 1)
    #expect(s.requests[1].value(forHTTPHeaderField: "Authorization") == "Bearer tok2")
}

@Test func secondUnauthorizedThrows() async {
    let s = State([(401, "", [:]), (401, "", [:])])
    await #expect(throws: AzureAPIError.unauthorized(nil)) {
        let _: Item = try await makeClient(s).get(url)
    }
    #expect(s.requests.count == 2)
}

@Test(arguments: [
    (403, AzureAPIError.forbidden(AzureErrorBody(code: "Forbidden", message: "no"))),
    (404, AzureAPIError.notFound(AzureErrorBody(code: "Forbidden", message: "no"))),
    (409, AzureAPIError.conflict(AzureErrorBody(code: "Forbidden", message: "no"))),
])
func mapsStatusErrors(status: Int, expected: AzureAPIError) async {
    let s = State([(status, #"{"error":{"code":"Forbidden","message":"no"}}"#, [:])])
    await #expect(throws: expected) {
        let _: Item = try await makeClient(s).get(url)
    }
}

@Test func mapsNetworkError() async {
    let s = State([])
    s.networkError = URLError(.cannotConnectToHost)
    await #expect(throws: AzureAPIError.network(.cannotConnectToHost)) {
        let _: Item = try await makeClient(s).get(url)
    }
}

@Test func backoffDoublesAndCapsAtMaxDelay() async {
    let s = State(Array(repeating: (503, "", [:]), count: 4))
    let client = AzureHTTPClient(
        tokenProvider: FakeTokens(s: s), tenant: "t", resource: .vault,
        transport: FakeTransport(s: s),
        retry: .init(maxRetries: 3, baseDelay: 1, maxDelay: 3),
        sleep: { d in s.lock.withLock { s.sleeps.append(d) } },
        jitter: { 1 })
    await #expect(throws: AzureAPIError.throttled(retryAfter: nil, nil)) {
        let _: Item = try await client.get(url)
    }
    #expect(s.sleeps == [1, 2, 3])
}

@Test func retryAfterHTTPDateIsHonoured() async throws {
    let fmt = DateFormatter()
    fmt.locale = Locale(identifier: "en_US_POSIX")
    fmt.timeZone = TimeZone(identifier: "GMT")
    fmt.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
    let header = fmt.string(from: Date().addingTimeInterval(60))
    let s = State([(429, "", ["Retry-After": header]), (200, #"{"id":1}"#, [:])])
    let _: Item = try await makeClient(s).get(url)
    #expect(s.sleeps.count == 1)
    #expect(s.sleeps[0] > 50 && s.sleeps[0] <= 60)
}

@Test func serverErrorIsMappedAndNotRetried() async {
    let s = State([(500, #"{"error":{"code":"Internal","message":"boom"}}"#, [:])])
    await #expect(throws: AzureAPIError.http(status: 500, AzureErrorBody(code: "Internal", message: "boom"))) {
        let _: Item = try await makeClient(s).get(url)
    }
    #expect(s.requests.count == 1)
    #expect(s.sleeps.isEmpty)
}

@Test func networkErrorIsNotRetried() async {
    let s = State([])
    s.networkError = URLError(.timedOut)
    await #expect(throws: AzureAPIError.network(.timedOut)) {
        let _: Item = try await makeClient(s).get(url)
    }
    #expect(s.requests.count == 1)
}

@Test func malformedBodyMapsToDecodingError() async {
    let s = State([(200, #"{"id":"not-an-int"}"#, [:])])
    do {
        let _: Item = try await makeClient(s).get(url)
        Issue.record("expected decoding error")
    } catch let AzureAPIError.decoding(message) {
        #expect(!message.isEmpty)
    } catch {
        Issue.record("unexpected error \(error)")
    }
}

@Test func errorBodyParsing() {
    let nested = Data(#"{"error":{"code":"SecretNotFound","message":"gone","innererror":{"x":1}}}"#.utf8)
    #expect(AzureErrorBody.parse(nested) == AzureErrorBody(code: "SecretNotFound", message: "gone"))
    #expect(AzureErrorBody.parse(Data("<html>bad gateway</html>".utf8)) == nil)
    #expect(AzureErrorBody.parse(Data()) == nil)
    #expect(AzureErrorBody.parse(Data(#"{"message":"flat"}"#.utf8)) == nil)
}

@Test func paginationStopsOnEmptyNextLinkAndPropagatesPageErrors() async {
    let ok = State([(200, #"{"value":[{"id":1}],"nextLink":""}"#, [:])])
    var all: [Item] = []
    do { for try await page in makeClient(ok).paginate(url, as: Item.self) { all += page } } catch {
        Issue.record("unexpected \(error)")
    }
    #expect(all.map(\.id) == [1])
    #expect(ok.requests.count == 1)

    let bad = State([
        (200, #"{"value":[{"id":1}],"nextLink":"https://v.vault.azure.net/secrets?p=2"}"#, [:]),
        (403, "", [:]),
    ])
    var seen: [Item] = []
    do {
        for try await page in makeClient(bad).paginate(url, as: Item.self) { seen += page }
        Issue.record("expected forbidden")
    } catch {
        #expect(error as? AzureAPIError == .forbidden(nil))
    }
    #expect(seen.map(\.id) == [1])
}
