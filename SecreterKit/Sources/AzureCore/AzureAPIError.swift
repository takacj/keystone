import Foundation

/// Typed errors surfaced by `AzureHTTPClient`.
public enum AzureAPIError: Error, Sendable, Equatable {
    /// 401 after the token was invalidated and the request retried once → re-login.
    case unauthorized(AzureErrorBody?)
    /// 403 → missing RBAC role / access policy.
    case forbidden(AzureErrorBody?)
    case notFound(AzureErrorBody?)
    /// 409 → e.g. a deleted secret with the same name exists.
    case conflict(AzureErrorBody?)
    /// 429 / 503 persisted after max retries.
    case throttled(retryAfter: TimeInterval?, AzureErrorBody?)
    /// Any other non-2xx status.
    case http(status: Int, AzureErrorBody?)
    /// Transport failure (DNS, firewall, private endpoint, offline…). Carries the URLError code.
    case network(URLError.Code)
    case decoding(String)
    case invalidURL(String)

    public var statusCode: Int? {
        switch self {
        case .unauthorized: 401
        case .forbidden: 403
        case .notFound: 404
        case .conflict: 409
        case .throttled: 429
        case .http(let status, _): status
        default: nil
        }
    }
}

/// Azure's standard `{"error":{"code","message"}}` payload.
public struct AzureErrorBody: Sendable, Equatable, Decodable {
    public let code: String?
    public let message: String?

    public init(code: String?, message: String?) {
        self.code = code
        self.message = message
    }

    private struct Envelope: Decodable { let error: AzureErrorBody }

    static func parse(_ data: Data) -> AzureErrorBody? {
        try? JSONDecoder().decode(Envelope.self, from: data).error
    }
}
