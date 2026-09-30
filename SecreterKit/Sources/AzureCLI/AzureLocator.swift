import Foundation

/// Finds the `az` executable (GUI apps don't inherit the shell PATH).
public struct AzureLocator: Sendable {
    public static let knownPaths = ["/opt/homebrew/bin/az", "/usr/local/bin/az"]

    private let isExecutable: @Sendable (String) -> Bool
    private let shellWhich: @Sendable () async -> String?

    public init(
        isExecutable: @escaping @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
        shellWhich: @escaping @Sendable () async -> String? = AzureLocator.loginShellWhich
    ) {
        self.isExecutable = isExecutable
        self.shellWhich = shellWhich
    }

    /// Probe order: Settings override → /opt/homebrew/bin/az → /usr/local/bin/az → `zsh -lc 'which az'`.
    /// - Throws: `AzureCLIError.notFound`
    public func locate(override: String? = nil) async throws -> URL {
        if let override = override?.trimmingCharacters(in: .whitespaces), !override.isEmpty {
            let path = (override as NSString).expandingTildeInPath
            if isExecutable(path) { return URL(fileURLWithPath: path) }
            // An invalid override is an error rather than silently falling back.
            throw AzureCLIError.notFound
        }
        for p in Self.knownPaths where isExecutable(p) { return URL(fileURLWithPath: p) }
        if let p = await shellWhich(), p.hasPrefix("/"), isExecutable(p) { return URL(fileURLWithPath: p) }
        throw AzureCLIError.notFound
    }

    /// Runs `az --version` and returns the parsed version.
    public static func version(of runner: any CLIRunning) async throws -> AzureVersion {
        let r = try await runner.run(["version", "-o", "json"], profileDir: nil, timeout: .seconds(30))
        guard let v = AzureVersion(parsing: r.stdout) else {
            throw AzureCLIError.commandFailed(exitCode: 0, stderr: "Unparseable az version output")
        }
        return v
    }

    /// `/bin/zsh -lc 'which az'`, 5 s cap.
    @Sendable public static func loginShellWhich() async -> String? {
        let job = ProcessJob(
            executable: URL(fileURLWithPath: "/bin/zsh"), arguments: ["-lc", "which az"],
            environment: ProcessInfo.processInfo.environment)
        let killer = Task {
            try await Task.sleep(for: .seconds(5))
            job.terminate(reason: .timeout)
        }
        defer { killer.cancel() }
        guard let r = try? await job.run(), r.exitCode == 0 else { return nil }
        let last = r.stdout.split(whereSeparator: \.isNewline).last.map(String.init)?
            .trimmingCharacters(in: .whitespaces)
        return last
    }
}
