import Foundation

/// Standard Azure list envelope.
public struct AzurePage<Element: Decodable & Sendable>: Decodable, Sendable {
    public let value: [Element]
    public let nextLink: String?
}

/// Bearer-authenticated JSON client with `nextLink` pagination, retry/backoff and typed errors.
public actor AzureHTTPClient {
    public struct RetryPolicy: Sendable {
        public var maxRetries: Int
        public var baseDelay: TimeInterval
        public var maxDelay: TimeInterval

        public init(maxRetries: Int = 3, baseDelay: TimeInterval = 0.5, maxDelay: TimeInterval = 30) {
            self.maxRetries = maxRetries
            self.baseDelay = baseDelay
            self.maxDelay = maxDelay
        }
    }

    private let tokenProvider: any TokenProvider
    private let tenant: String
    private let resource: AzureResource
    private let transport: any HTTPTransport
    private let retry: RetryPolicy
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private let jitter: @Sendable () -> Double
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    public init(
        tokenProvider: any TokenProvider,
        tenant: String,
        resource: AzureResource,
        transport: any HTTPTransport = URLSession.shared,
        retry: RetryPolicy = RetryPolicy(),
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = {
            try await Task.sleep(for: .seconds($0))
        },
        jitter: @escaping @Sendable () -> Double = { Double.random(in: 0...1) }
    ) {
        self.tokenProvider = tokenProvider
        self.tenant = tenant
        self.resource = resource
        self.transport = transport
        self.retry = retry
        self.sleep = sleep
        self.jitter = jitter
        decoder = JSONDecoder()
        encoder = JSONEncoder()
    }

    // MARK: - Typed API

    public func get<T: Decodable & Sendable>(_ url: URL, as type: T.Type = T.self) async throws -> T {
        try decode(try await send(url: url, method: "GET", body: nil).0)
    }

    public func send<B: Encodable, T: Decodable & Sendable>(
        _ method: String, _ url: URL, body: B, as type: T.Type = T.self
    ) async throws -> T {
        let payload = try encoder.encode(body)
        return try decode(try await send(url: url, method: method, body: payload).0)
    }

    /// Requests with no response body of interest (e.g. DELETE).
    public func perform(_ method: String, _ url: URL) async throws {
        _ = try await send(url: url, method: method, body: nil)
    }

    /// Streams pages (arrays of elements), following `nextLink` until exhausted.
    public nonisolated func paginate<T: Decodable & Sendable>(
        _ url: URL, as type: T.Type = T.self
    ) -> AsyncThrowingStream<[T], Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var next: URL? = url
                    while let current = next {
                        try Task.checkCancellation()
                        let page: AzurePage<T> = try await self.get(current)
                        continuation.yield(page.value)
                        if let link = page.nextLink, !link.isEmpty {
                            guard let u = URL(string: link) else { throw AzureAPIError.invalidURL(link) }
                            next = u
                        } else {
                            next = nil
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Core

    /// Sends with auth, 401-refresh-once, and 429/503 backoff.
    public func send(url: URL, method: String, body: Data?) async throws -> (Data, HTTPURLResponse) {
        var retries = 0
        var refreshed = false
        while true {
            let token = try await tokenProvider.token(tenant: tenant, resource: resource)
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.setValue("Bearer \(token.value)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            if let body {
                request.httpBody = body
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }

            let data: Data
            let response: HTTPURLResponse
            do {
                (data, response) = try await transport.send(request)
            } catch let error as URLError where error.code != .cancelled {
                throw AzureAPIError.network(error.code)
            }

            let status = response.statusCode
            if (200..<300).contains(status) { return (data, response) }
            let errBody = AzureErrorBody.parse(data)
            let retryAfter = Self.retryAfter(response)

            switch status {
            case 401:
                if refreshed { throw AzureAPIError.unauthorized(errBody) }
                refreshed = true
                await tokenProvider.invalidate(tenant: tenant, resource: resource)
            case 429, 503:
                if retries >= retry.maxRetries { throw AzureAPIError.throttled(retryAfter: retryAfter, errBody) }
                let backoff = min(retry.baseDelay * pow(2, Double(retries)), retry.maxDelay)
                let delay = max(retryAfter ?? 0, backoff * (0.5 + 0.5 * jitter()))
                retries += 1
                try await sleep(delay)
            case 403: throw AzureAPIError.forbidden(errBody)
            case 404: throw AzureAPIError.notFound(errBody)
            case 409: throw AzureAPIError.conflict(errBody)
            default: throw AzureAPIError.http(status: status, errBody)
            }
        }
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        do { return try decoder.decode(T.self, from: data) } catch {
            throw AzureAPIError.decoding(String(describing: error))
        }
    }

    private static func retryAfter(_ response: HTTPURLResponse) -> TimeInterval? {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After") else { return nil }
        if let seconds = TimeInterval(raw.trimmingCharacters(in: .whitespaces)) { return max(0, seconds) }
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(identifier: "GMT")
        fmt.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return fmt.date(from: raw).map { max(0, $0.timeIntervalSinceNow) }
    }
}
