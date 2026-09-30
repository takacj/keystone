import Foundation

/// Azure resource (audience) a token is requested for.
public enum AzureResource: String, Sendable, Hashable {
    case arm = "https://management.azure.com/"
    case vault = "https://vault.azure.net"
}

public struct AccessToken: Sendable, Equatable {
    public let value: String
    public let expiresOn: Date

    public init(value: String, expiresOn: Date) {
        self.value = value
        self.expiresOn = expiresOn
    }
}

/// Supplies bearer tokens. Implemented by AzureAuth (bound to one account).
public protocol TokenProvider: Sendable {
    func token(tenant: String, resource: AzureResource) async throws -> AccessToken
    /// Drop any cached token so the next `token` call fetches a fresh one.
    func invalidate(tenant: String, resource: AzureResource) async
}
