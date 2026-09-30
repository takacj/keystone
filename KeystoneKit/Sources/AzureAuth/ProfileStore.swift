import AzureCLI
import Foundation

/// Manages account profiles: per-account `AZURE_CONFIG_DIR` directories plus `accounts.json`.
public actor ProfileStore {
    public let rootDirectory: URL
    private let runner: any CLIRunning
    private let fileManager: FileManager
    private var cache: [AccountProfile]?

    /// Default root: `~/Library/Application Support/Keystone`.
    public static var defaultRootDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Keystone", isDirectory: true)
    }

    public init(
        rootDirectory: URL = ProfileStore.defaultRootDirectory,
        runner: any CLIRunning,
        fileManager: FileManager = .default
    ) {
        self.rootDirectory = rootDirectory
        self.runner = runner
        self.fileManager = fileManager
    }

    public var profilesDirectory: URL { rootDirectory.appendingPathComponent("profiles", isDirectory: true) }
    var accountsFile: URL { rootDirectory.appendingPathComponent("accounts.json") }

    public func profileDirectory(for id: UUID) -> URL {
        profilesDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    // MARK: Read

    public func accounts() throws -> [AccountProfile] {
        if let cache { return cache }
        guard fileManager.fileExists(atPath: accountsFile.path) else { return [] }
        let stored: [AccountProfile]
        do {
            stored = try JSONDecoder().decode([AccountProfile].self, from: Data(contentsOf: accountsFile))
        } catch {
            throw ProfileStoreError.storageFailed(error.localizedDescription)
        }
        // Profile dirs always live under the current root; stored absolute paths go stale when the
        // root moves (e.g. after the data directory was renamed), so re-derive them from the id.
        let list = stored.map { profile in
            var profile = profile
            profile.profileDir = profileDirectory(for: profile.id)
            return profile
        }
        if list.map(\.profileDir) != stored.map(\.profileDir) { try save(list) }
        cache = list
        return list
    }

    public func account(id: UUID) throws -> AccountProfile {
        guard let a = try accounts().first(where: { $0.id == id }) else { throw ProfileStoreError.accountNotFound(id) }
        return a
    }

    // MARK: Add

    /// Runs `az login` in a fresh profile dir, reads `az account show`, persists the account.
    /// On any failure the new profile dir is deleted.
    @discardableResult
    public func addAccount(
        displayName: String? = nil,
        options: AccountLoginOptions = AccountLoginOptions(),
        onOutput: (@Sendable (String) -> Void)? = nil
    ) async throws -> AccountProfile {
        let id = UUID()
        let dir = profileDirectory(for: id)
        do {
            try fileManager.createDirectory(
                at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try await login(options.arguments, profileDir: dir, onOutput: onOutput)
            let info = try await accountInfo(profileDir: dir)
            let trimmed = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
            let profile = AccountProfile(
                id: id,
                displayName: (trimmed?.isEmpty == false ? trimmed : nil) ?? info.upn,
                upn: info.upn,
                homeTenantId: info.homeTenantId,
                profileDir: dir
            )
            var list = try accounts()
            list.append(profile)
            try save(list)
            return profile
        } catch {
            try? fileManager.removeItem(at: dir)
            throw error
        }
    }

    // MARK: Re-login

    /// Runs `az login --tenant <tenantId>` in the account's existing profile; refreshes upn/home tenant.
    @discardableResult
    public func reLogin(
        id: UUID, tenant: String, useDeviceCode: Bool = false,
        onOutput: (@Sendable (String) -> Void)? = nil
    ) async throws -> AccountProfile {
        var profile = try account(id: id)
        let opts = AccountLoginOptions(useDeviceCode: useDeviceCode, tenant: tenant)
        try await login(opts.arguments, profileDir: profile.profileDir, onOutput: onOutput)
        if let info = try? await accountInfo(profileDir: profile.profileDir) {
            profile.upn = info.upn
            profile.homeTenantId = info.homeTenantId
            var list = try accounts()
            if let i = list.firstIndex(where: { $0.id == id }) { list[i] = profile }
            try save(list)
        }
        return profile
    }

    // MARK: Rename / Remove

    public func rename(id: UUID, to name: String) throws {
        var list = try accounts()
        guard let i = list.firstIndex(where: { $0.id == id }) else { throw ProfileStoreError.accountNotFound(id) }
        list[i].displayName = name
        try save(list)
    }

    /// `az logout` + `az account clear` (best effort), then deletes the profile dir and the record.
    public func removeAccount(id: UUID) async throws {
        let profile = try account(id: id)
        _ = try? await runner.run(["logout"], profileDir: profile.profileDir)
        _ = try? await runner.run(["account", "clear"], profileDir: profile.profileDir)
        if fileManager.fileExists(atPath: profile.profileDir.path) {
            try fileManager.removeItem(at: profile.profileDir)
        }
        try save(try accounts().filter { $0.id != id })
    }

    // MARK: Private

    /// Runs `az login`; with `onOutput` and a streaming-capable runner, lines are reported live.
    private func login(_ args: [String], profileDir: URL, onOutput: (@Sendable (String) -> Void)?) async throws {
        if let onOutput, let streaming = runner as? any StreamingCLIRunning {
            _ = try await streaming.runStreaming(
                args, profileDir: profileDir, timeout: CLIRunner.loginTimeout, onLine: onOutput)
        } else {
            _ = try await runner.run(args, profileDir: profileDir, timeout: CLIRunner.loginTimeout)
        }
    }

    private func accountInfo(profileDir: URL) async throws -> AzureAccountInfo {
        let result = try await runner.run(["account", "show", "-o", "json"], profileDir: profileDir)
        return try AzureAccountInfo.parse(result.stdout)
    }

    private func save(_ list: [AccountProfile]) throws {
        do {
            try fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(list).write(to: accountsFile, options: .atomic)
            cache = list
        } catch {
            throw ProfileStoreError.storageFailed(error.localizedDescription)
        }
    }
}
