import Foundation

public struct CLIResult: Sendable, Equatable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
    public init(exitCode: Int32, stdout: String, stderr: String) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

/// Injectable abstraction so higher layers can use a fake in tests.
public protocol CLIRunning: Sendable {
    /// Runs `az <arguments>`. Throws `AzureCLIError` on failure (non-zero exit is mapped from stderr).
    /// - Parameter profileDir: becomes `AZURE_CONFIG_DIR`; nil uses az's default.
    func run(_ arguments: [String], profileDir: URL?, timeout: Duration) async throws -> CLIResult
}

extension CLIRunning {
    public func run(_ arguments: [String], profileDir: URL? = nil) async throws -> CLIResult {
        try await run(arguments, profileDir: profileDir, timeout: CLIRunner.defaultTimeout)
    }
}

/// Runs an executable (normally `az`) with an isolated profile environment, timeout and cancellation.
public actor CLIRunner: CLIRunning {
    public static let defaultTimeout: Duration = .seconds(30)
    /// Interactive commands (`az login`) need much longer.
    public static let loginTimeout: Duration = .seconds(300)

    /// Arguments that would put a secret on the command line (visible in `ps`).
    static let forbiddenArguments: Set<String> = [
        "--value", "--password", "-p", "--client-secret", "--service-principal-secret", "--file-password",
    ]

    public let executable: URL
    private let extraEnvironment: [String: String]

    public init(executable: URL, extraEnvironment: [String: String] = [:]) {
        self.executable = executable
        self.extraEnvironment = extraEnvironment
    }

    /// Environment for an invocation (exposed for tests).
    public static func environment(
        profileDir: URL?, base: [String: String] = ProcessInfo.processInfo.environment,
        extra: [String: String] = [:]
    ) -> [String: String] {
        var env = base
        let extraPaths = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        env["PATH"] = [base["PATH"], extraPaths].compactMap { $0 }.joined(separator: ":")
        env["AZURE_CORE_ONLY_SHOW_ERRORS"] = "1"
        env["AZURE_CORE_NO_COLOR"] = "true"
        env["AZURE_CORE_COLLECT_TELEMETRY"] = "false"
        env["AZURE_CORE_OUTPUT"] = nil
        if let profileDir { env["AZURE_CONFIG_DIR"] = profileDir.path }
        for (k, v) in extra { env[k] = v }
        return env
    }

    public func run(
        _ arguments: [String], profileDir: URL? = nil, timeout: Duration = CLIRunner.defaultTimeout
    ) async throws -> CLIResult {
        try await execute(arguments, profileDir: profileDir, timeout: timeout, onLine: nil)
    }

    func execute(
        _ arguments: [String], profileDir: URL?, timeout: Duration,
        onLine: (@Sendable (String) -> Void)?
    ) async throws -> CLIResult {
        for a in arguments {
            let name = a.split(separator: "=", maxSplits: 1).first.map(String.init) ?? a
            if Self.forbiddenArguments.contains(name) { throw AzureCLIError.forbiddenArgument(name) }
        }
        let env = Self.environment(profileDir: profileDir, extra: extraEnvironment)
        let job = ProcessJob(executable: executable, arguments: arguments, environment: env)
        job.onLine = onLine

        let result: CLIResult
        do {
            result = try await withTaskCancellationHandler {
                try await withThrowingTaskGroup(of: CLIResult?.self) { group in
                    group.addTask { try await job.run() }
                    group.addTask {
                        try await Task.sleep(for: timeout)
                        job.terminate(reason: .timeout)
                        return nil
                    }
                    defer { group.cancelAll() }
                    while let r = try await group.next() {
                        if let r { return r }
                    }
                    throw AzureCLIError.cancelled
                }
            } onCancel: {
                job.terminate(reason: .cancelled)
            }
        } catch is CancellationError {
            throw AzureCLIError.cancelled
        }

        switch job.terminationReason {
        case .timeout: throw AzureCLIError.timedOut(after: timeout)
        case .cancelled: throw AzureCLIError.cancelled
        case nil: break
        }
        if result.exitCode != 0 {
            throw AzureCLIErrorParser.parse(stderr: result.stderr, exitCode: result.exitCode)
        }
        return result
    }
}

/// One process execution. Thread-safe via a lock.
final class ProcessJob: @unchecked Sendable {
    enum Reason { case timeout, cancelled }

    private let process = Process()
    private let outPipe = Pipe()
    private let errPipe = Pipe()
    private let lock = NSLock()
    private var out = Data()
    private var err = Data()
    private var reason: Reason?
    private var started = false
    private var pending = [Data(), Data()]  // partial lines: [stdout, stderr]
    /// Called (off the main thread) for each complete stdout/stderr line while the process runs.
    var onLine: (@Sendable (String) -> Void)?

    init(executable: URL, arguments: [String], environment: [String: String]) {
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outPipe
        process.standardError = errPipe
    }

    var terminationReason: Reason? {
        lock.lock()
        defer { lock.unlock() }
        return reason
    }

    func terminate(reason newReason: Reason) {
        lock.lock()
        if reason == nil { reason = newReason }
        let running = started && process.isRunning
        lock.unlock()
        if running { process.terminate() }
    }

    func run() async throws -> CLIResult {
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            self?.append(d, toErr: false)
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            self?.append(d, toErr: true)
        }
        let code: Int32 = try await withCheckedThrowingContinuation { cont in
            process.terminationHandler = { p in cont.resume(returning: p.terminationStatus) }
            do {
                lock.lock()
                if reason != nil {  // cancelled/timed out before launch
                    lock.unlock()
                    cont.resume(throwing: AzureCLIError.cancelled)
                    return
                }
                try process.run()
                started = true
                lock.unlock()
            } catch {
                lock.unlock()
                let ns = error as NSError
                let notFound =
                    ns.domain == NSCocoaErrorDomain
                    && (ns.code == NSFileNoSuchFileError || ns.code == NSFileReadNoSuchFileError)
                cont.resume(
                    throwing: notFound ? AzureCLIError.notFound : AzureCLIError.launchFailed(error.localizedDescription)
                )
            }
        }
        // Drain remaining output.
        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil
        flushLines(final: false)
        let restOut = (try? outPipe.fileHandleForReading.readToEnd()) ?? nil
        let restErr = (try? errPipe.fileHandleForReading.readToEnd()) ?? nil
        let (o, e): (Data, Data) = lock.withLock {
            if let restOut { out.append(restOut) }
            if let restErr { err.append(restErr) }
            return (out, err)
        }
        return CLIResult(
            exitCode: code, stdout: String(decoding: o, as: UTF8.self), stderr: String(decoding: e, as: UTF8.self))
    }

    private func append(_ d: Data, toErr: Bool) {
        guard !d.isEmpty else { return }
        lock.lock()
        if toErr { err.append(d) } else { out.append(d) }
        lock.unlock()
        if onLine != nil { feedLines(d, index: toErr ? 1 : 0) }
    }

    private func feedLines(_ d: Data, index: Int) {
        var lines: [String] = []
        lock.lock()
        pending[index].append(d)
        while let nl = pending[index].firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            let line = pending[index][pending[index].startIndex..<nl]
            if !line.isEmpty { lines.append(String(decoding: line, as: UTF8.self)) }
            pending[index].removeSubrange(pending[index].startIndex...nl)
        }
        lock.unlock()
        for l in lines { onLine?(l) }
    }

    private func flushLines(final: Bool) {
        guard let onLine else { return }
        lock.lock()
        let rest = pending.map { String(decoding: $0, as: UTF8.self) }
        pending = [Data(), Data()]
        lock.unlock()
        for l in rest where !l.isEmpty { onLine(l) }
    }
}
