import AzureCore
import Foundation

/// ARM control-plane client. Uses a per-tenant ARM token for every call.
public struct ARMClient: Sendable {
    public static let baseURL = URL(string: "https://management.azure.com")!
    static let subscriptionsAPI = "2022-12-01"
    static let vaultsAPI = "2023-07-01"

    private let tokenProvider: any TokenProvider
    private let transport: any HTTPTransport
    private let retry: AzureHTTPClient.RetryPolicy

    public init(
        tokenProvider: any TokenProvider,
        transport: any HTTPTransport = URLSession.shared,
        retry: AzureHTTPClient.RetryPolicy = .init()
    ) {
        self.tokenProvider = tokenProvider
        self.transport = transport
        self.retry = retry
    }

    func makeClient(tenant: String) -> AzureHTTPClient {
        client(tenant: tenant)
    }

    private func client(tenant: String) -> AzureHTTPClient {
        AzureHTTPClient(
            tokenProvider: tokenProvider, tenant: tenant, resource: .arm,
            transport: transport, retry: retry)
    }

    private func url(_ path: String, api: String) -> URL {
        var c = URLComponents(url: Self.baseURL, resolvingAgainstBaseURL: false)!
        c.path = path
        c.queryItems = [URLQueryItem(name: "api-version", value: api)]
        return c.url!
    }

    private func collect<T: Decodable & Sendable>(_ url: URL, tenant: String, as: T.Type) async throws -> [T] {
        var all: [T] = []
        for try await page in client(tenant: tenant).paginate(url, as: T.self) { all += page }
        return all
    }

    /// Tenants visible to the account; `homeTenant` selects the token used.
    public func tenants(homeTenant: String) async throws -> [Tenant] {
        try await collect(url("/tenants", api: Self.subscriptionsAPI), tenant: homeTenant, as: Tenant.self)
    }

    /// Subscriptions in `tenant` (token for that tenant).
    public func subscriptions(tenant: String) async throws -> [Subscription] {
        try await collect(url("/subscriptions", api: Self.subscriptionsAPI), tenant: tenant, as: Subscription.self)
    }

    /// Key vaults in a subscription (token for the owning tenant).
    public func vaults(subscriptionId: String, tenant: String) async throws -> [Vault] {
        try await collect(
            url("/subscriptions/\(subscriptionId)/providers/Microsoft.KeyVault/vaults", api: Self.vaultsAPI),
            tenant: tenant, as: Vault.self)
    }
}
