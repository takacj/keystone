import Foundation

/// A runner that can report output lines live (needed for `az login --use-device-code`,
/// which prints the code on stderr while the process keeps running).
public protocol StreamingCLIRunning: CLIRunning {
    /// Like `run`, additionally invoking `onLine` for every stdout/stderr line as it arrives.
    func runStreaming(
        _ arguments: [String], profileDir: URL?, timeout: Duration,
        onLine: @escaping @Sendable (String) -> Void
    ) async throws -> CLIResult
}

extension CLIRunner: StreamingCLIRunning {
    public func runStreaming(
        _ arguments: [String], profileDir: URL?, timeout: Duration,
        onLine: @escaping @Sendable (String) -> Void
    ) async throws -> CLIResult {
        try await execute(arguments, profileDir: profileDir, timeout: timeout, onLine: onLine)
    }
}

/// The "open this page and enter this code" instruction printed by `az login --use-device-code`.
public struct DeviceCodePrompt: Sendable, Equatable {
    public let url: URL
    public let code: String

    public init(url: URL, code: String) {
        self.url = url
        self.code = code
    }

    /// Parses e.g. `To sign in, use a web browser to open the page https://microsoft.com/devicelogin
    /// and enter the code ABC123XYZ to authenticate.` Returns nil for other lines.
    public static func parse(_ line: String) -> DeviceCodePrompt? {
        guard let urlRange = line.range(of: #"https?://\S+"#, options: .regularExpression),
            let codeRange = line.range(of: #"(?<=enter the code )[A-Z0-9]+"#, options: .regularExpression),
            let url = URL(string: String(line[urlRange]))
        else { return nil }
        return DeviceCodePrompt(url: url, code: String(line[codeRange]))
    }
}
