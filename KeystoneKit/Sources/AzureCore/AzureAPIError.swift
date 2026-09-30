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

extension AzureAPIError: LocalizedError {
    /// Readable fallback for views that show `localizedDescription` (instead of "AzureAPIError error N").
    public var errorDescription: String? {
        switch self {
        case .unauthorized(let body): Self.describe("Not authorized (401). Sign in again.", body)
        case .forbidden(let body): Self.describe("Access denied (403).", body)
        case .notFound(let body): Self.describe("Not found (404).", body)
        case .conflict(let body): Self.describe("Conflict (409).", body)
        case .throttled(_, let body): Self.describe("Azure is throttling requests (429). Try again shortly.", body)
        case .http(let status, let body): Self.describe("Request failed (HTTP \(status)).", body)
        case .network(let code): "Network error (\(code.rawValue)). Check connectivity, firewall or private endpoint."
        case .decoding(let what): "Unexpected response from Azure (\(what))."
        case .invalidURL(let url): "Invalid request URL (\(url))."
        }
    }

    private static func describe(_ summary: String, _ body: AzureErrorBody?) -> String {
        guard let message = body?.message, !message.isEmpty else { return summary }
        return "\(summary) \(message)"
    }
}

/// Azure's standard `{"error":{"code","message"}}` payload.
public struct AzureErrorBody: Sendable, Equatable, Decodable {
    public let code: String?
    public let message: String?
    /// `error.innererror.code`, e.g. Key Vault's `ForbiddenByFirewall` under a generic `Forbidden`.
    public let innerCode: String?

    public init(code: String?, message: String?, innerCode: String? = nil) {
        self.code = code
        self.message = message
        self.innerCode = innerCode
    }

    private enum CodingKeys: String, CodingKey { case code, message, innererror }
    private struct Inner: Decodable { let code: String? }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        code = try c.decodeIfPresent(String.self, forKey: .code)
        message = try c.decodeIfPresent(String.self, forKey: .message)
        innerCode = try c.decodeIfPresent(Inner.self, forKey: .innererror)?.code
    }

    private struct Envelope: Decodable { let error: AzureErrorBody }

    static func parse(_ data: Data) -> AzureErrorBody? {
        try? JSONDecoder().decode(Envelope.self, from: data).error
    }
}
