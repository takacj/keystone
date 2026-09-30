import AzureCLI
import AzureCore
import Foundation

public enum AzureCLITokenError: Error, Equatable {
    case malformedOutput(String)
}

/// `TokenProvider` backed by `az account get-access-token`, bound to one account's profile dir.
/// Caches per (tenant, resource) until `refreshMargin` before expiry and shares in-flight fetches.
public actor AzureCLITokenProvider: TokenProvider {
    struct Key: Hashable, Sendable {
        let tenant: String
        let resource: AzureResource
    }

    public static let defaultRefreshMargin: TimeInterval = 300

    private let runner: any CLIRunning
    private let profileDir: URL?
    private let refreshMargin: TimeInterval
    private let now: @Sendable () -> Date
    private var cache: [Key: AccessToken] = [:]
    private var inFlight: [Key: (id: UUID, task: Task<AccessToken, Error>)] = [:]

    public init(
        runner: any CLIRunning,
        profileDir: URL?,
        refreshMargin: TimeInterval = AzureCLITokenProvider.defaultRefreshMargin,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.runner = runner
        self.profileDir = profileDir
        self.refreshMargin = refreshMargin
        self.now = now
    }

    public func token(tenant: String, resource: AzureResource) async throws -> AccessToken {
        let key = Key(tenant: tenant, resource: resource)
        if let cached = cache[key], cached.expiresOn.timeIntervalSince(now()) > refreshMargin {
            return cached
        }
        if let existing = inFlight[key] {
            return try await existing.task.value
        }
        let id = UUID()
        let runner = runner
        let profileDir = profileDir
        let task = Task<AccessToken, Error> {
            let result = try await runner.run(
                [
                    "account", "get-access-token",
                    "--tenant", tenant,
                    "--resource", resource.rawValue,
                    "-o", "json",
                ],
                profileDir: profileDir
            )
            return try Self.parse(result.stdout)
        }
        inFlight[key] = (id, task)
        do {
            let token = try await task.value
            finish(key, id: id, token: token)
            return token
        } catch {
            finish(key, id: id, token: nil)
            throw error
        }
    }

    public func invalidate(tenant: String, resource: AzureResource) async {
        let key = Key(tenant: tenant, resource: resource)
        cache[key] = nil
        // Drop the shared fetch so callers after a 401 start a fresh one.
        inFlight[key] = nil
    }

    private func finish(_ key: Key, id: UUID, token: AccessToken?) {
        guard inFlight[key]?.id == id else { return }  // invalidated meanwhile
        inFlight[key] = nil
        if let token { cache[key] = token }
    }

    // MARK: Parsing

    static func parse(_ stdout: String) throws -> AccessToken {
        guard let data = stdout.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let value = obj["accessToken"] as? String, !value.isEmpty
        else { throw AzureCLITokenError.malformedOutput("missing accessToken") }
        if let epoch = obj["expires_on"] as? Double {
            return AccessToken(value: value, expiresOn: Date(timeIntervalSince1970: epoch))
        }
        if let s = obj["expires_on"] as? String, let epoch = Double(s) {
            return AccessToken(value: value, expiresOn: Date(timeIntervalSince1970: epoch))
        }
        // Older az: "expiresOn": "2026-01-01 12:00:00.000000" in local time.
        if let s = obj["expiresOn"] as? String {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = .current
            for fmt in ["yyyy-MM-dd HH:mm:ss.SSSSSS", "yyyy-MM-dd HH:mm:ss"] {
                f.dateFormat = fmt
                if let d = f.date(from: s) { return AccessToken(value: value, expiresOn: d) }
            }
        }
        throw AzureCLITokenError.malformedOutput("missing expires_on")
    }
}
