import AzureCore
import Foundation

/// Single place for the data-plane API version.
public let keyVaultAPIVersion = "7.5"

/// Bulk concurrency limit per vault (Key Vault throttling).
public let keyVaultBulkConcurrency = 4

/// Key Vault secrets data-plane client for one vault. Never logs secret values.
public struct KeyVaultSecretsClient: Sendable {
    public let vaultURI: URL
    private let http: AzureHTTPClient

    /// - Parameter http: client created with `resource: .vault`.
    public init(vaultURI: URL, http: AzureHTTPClient) {
        self.vaultURI = vaultURI
        self.http = http
    }

    // MARK: Secrets

    /// Streams pages of secret metadata (25 per page), following `nextLink`.
    public func listSecrets(maxResults: Int = 25) -> AsyncThrowingStream<[SecretItem], Error> {
        do { return http.paginate(try url(["secrets"], ["maxresults": "\(maxResults)"])) } catch {
            return Self.failed(error)
        }
    }

    public func listVersions(name: String, maxResults: Int = 25) -> AsyncThrowingStream<[SecretItem], Error> {
        do {
            return http.paginate(try url(["secrets", name, "versions"], ["maxresults": "\(maxResults)"]))
        } catch { return Self.failed(error) }
    }

    /// Current value when `version` is nil.
    public func getSecret(name: String, version: String? = nil) async throws -> SecretBundle {
        try await http.get(try url(["secrets", name] + (version.map { [$0] } ?? [])))
    }

    /// Creates a new version.
    public func setSecret(name: String, _ request: SetSecretRequest) async throws -> SecretBundle {
        try await http.send("PUT", try url(["secrets", name]), body: request)
    }

    /// Updates metadata of a specific version (empty version = latest).
    public func updateSecret(
        name: String, version: String, _ request: UpdateSecretRequest
    ) async throws -> SecretBundle {
        try await http.send("PATCH", try url(["secrets", name, version]), body: request)
    }

    /// Soft-deletes; 409 is thrown if a deleted secret with this name exists.
    @discardableResult
    public func deleteSecret(name: String) async throws -> DeletedSecretBundle {
        let (data, _) = try await http.send(url: try url(["secrets", name]), method: "DELETE", body: nil)
        return try Self.decode(data)
    }

    // MARK: Deleted secrets

    public func listDeletedSecrets(maxResults: Int = 25) -> AsyncThrowingStream<[DeletedSecretItem], Error> {
        do {
            return http.paginate(try url(["deletedsecrets"], ["maxresults": "\(maxResults)"]))
        } catch { return Self.failed(error) }
    }

    @discardableResult
    public func recoverDeletedSecret(name: String) async throws -> SecretBundle {
        let (data, _) = try await http.send(
            url: try url(["deletedsecrets", name, "recover"]), method: "POST", body: nil)
        return try Self.decode(data)
    }

    /// Permanently deletes (requires purge permission; fails if purge protection is on).
    public func purgeDeletedSecret(name: String) async throws {
        try await http.perform("DELETE", try url(["deletedsecrets", name]))
    }

    // MARK: Bulk

    /// Runs `operation` over `items` with at most `limit` in flight. Results keep input order;
    /// per-item failures are captured, not thrown.
    public static func bulk<Input: Sendable, Output: Sendable>(
        _ items: [Input], limit: Int = keyVaultBulkConcurrency,
        _ operation: @escaping @Sendable (Input) async throws -> Output
    ) async -> [(input: Input, result: Result<Output, Error>)] {
        var results = [Result<Output, Error>?](repeating: nil, count: items.count)
        await withTaskGroup(of: (Int, Result<Output, Error>).self) { group in
            var next = 0
            func launch() {
                guard next < items.count else { return }
                let i = next
                next += 1
                let item = items[i]
                group.addTask {
                    do { return (i, .success(try await operation(item))) } catch { return (i, .failure(error)) }
                }
            }
            for _ in 0..<max(1, min(limit, items.count)) { launch() }
            while let (i, r) = await group.next() {
                results[i] = r
                launch()
            }
        }
        return zip(items, results).map { ($0, $1 ?? .failure(CancellationError())) }
    }

    // MARK: Helpers

    private func url(_ path: [String], _ query: [String: String] = [:]) throws -> URL {
        guard var c = URLComponents(url: vaultURI, resolvingAgainstBaseURL: false) else {
            throw AzureAPIError.invalidURL(vaultURI.absoluteString)
        }
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))
        let encoded = try path.map { seg -> String in
            guard !seg.isEmpty, let e = seg.addingPercentEncoding(withAllowedCharacters: allowed) else {
                throw AzureAPIError.invalidURL(seg)
            }
            return e
        }
        c.percentEncodedPath = "/" + encoded.joined(separator: "/")
        c.queryItems =
            query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
            + [URLQueryItem(name: "api-version", value: keyVaultAPIVersion)]
        guard let u = c.url else { throw AzureAPIError.invalidURL(vaultURI.absoluteString) }
        return u
    }

    private static func decode<T: Decodable>(_ data: Data) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: data) } catch {
            throw AzureAPIError.decoding(String(describing: type(of: error)))
        }
    }

    private static func failed<T>(_ error: Error) -> AsyncThrowingStream<T, Error> {
        AsyncThrowingStream { $0.finish(throwing: error) }
    }
}
