import AzureCore
import Foundation

extension ARMClient {
    static let resourceGraphAPI = "2022-10-01"
    static let resourceGraphVaultQuery = "resources | where type == 'microsoft.keyvault/vaults'"

    private struct GraphRequest: Encodable {
        struct Options: Encodable {
            let resultFormat = "objectArray"
            let top: Int
            let skipToken: String?
            private enum CodingKeys: String, CodingKey {
                case resultFormat
                case top = "$top"
                case skipToken = "$skipToken"
            }
        }
        let query: String
        let subscriptions: [String]?
        let options: Options
    }

    private struct GraphResponse: Decodable {
        let data: [Vault]
        let skipToken: String?
        private enum CodingKeys: String, CodingKey {
            case data
            case skipToken = "$skipToken"
        }
    }

    /// All key vaults the account can see across subscriptions of `tenant`, in one Resource Graph query
    /// (POST /providers/Microsoft.ResourceGraph/resources, 2022-10-01), following `$skipToken` paging.
    /// - Parameters:
    ///   - subscriptions: optional subscription-id scope; `nil` = every subscription visible in the tenant.
    ///   - pageSize: `$top` per page (max 1000).
    public func discoverVaults(
        tenant: String, subscriptions: [String]? = nil, pageSize: Int = 1000
    ) async throws -> [Vault] {
        var c = URLComponents(url: Self.baseURL, resolvingAgainstBaseURL: false)!
        c.path = "/providers/Microsoft.ResourceGraph/resources"
        c.queryItems = [URLQueryItem(name: "api-version", value: Self.resourceGraphAPI)]
        let url = c.url!
        let http = makeClient(tenant: tenant)

        var all: [Vault] = []
        var skipToken: String?
        var seen = Set<String>()
        repeat {
            let body = GraphRequest(
                query: Self.resourceGraphVaultQuery, subscriptions: subscriptions,
                options: .init(top: min(max(pageSize, 1), 1000), skipToken: skipToken))
            let page: GraphResponse = try await http.send("POST", url, body: body)
            all += page.data
            let next = page.skipToken.flatMap { $0.isEmpty ? nil : $0 }
            // Guard against a server echoing the same token forever.
            if let next, !seen.insert(next).inserted { break }
            skipToken = next
        } while skipToken != nil
        return all
    }
}
