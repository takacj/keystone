import Foundation

/// Errors produced by the `az` locator and runner.
public enum AzureCLIError: Error, Equatable, Sendable {
    /// `az` binary could not be located (or is not executable).
    case notFound
    /// Process could not be launched.
    case launchFailed(String)
    /// Not signed in / token expired; user must run `az login`.
    case loginRequired(message: String)
    /// MFA / Conditional Access / interaction needed; re-login to the tenant.
    case interactionRequired(code: String?, message: String)
    /// Process exceeded its timeout and was terminated.
    case timedOut(after: Duration)
    /// Task was cancelled; process was terminated.
    case cancelled
    /// An argument that could carry a secret was passed on the command line.
    case forbiddenArgument(String)
    /// Any other non-zero exit.
    case commandFailed(exitCode: Int32, stderr: String)
}

extension AzureCLIError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notFound: "Azure CLI (az) was not found. Install it with: brew install azure-cli"
        case .launchFailed(let m): "Could not launch az: \(m)"
        case .loginRequired(let m): m.isEmpty ? "Sign in again." : m
        case .interactionRequired(_, let m): m.isEmpty ? "Re-login to this tenant." : m
        case .timedOut(let d): "az timed out after \(d)."
        case .cancelled: "Operation cancelled."
        case .forbiddenArgument(let a): "Refusing to pass \(a) on the command line."
        case .commandFailed(_, let s): s.isEmpty ? "az failed." : s
        }
    }
}

/// Maps `az` stderr text to typed errors.
public enum AzureCLIErrorParser {
    /// AADSTS codes that require interactive re-login to the tenant.
    public static let interactionCodes: Set<String> = ["AADSTS50076", "AADSTS50079", "AADSTS700082"]

    public static func parse(stderr: String, exitCode: Int32) -> AzureCLIError {
        let text = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()

        if lower.contains("command not found") || lower.contains("no such file or directory: 'az'") {
            return .notFound
        }
        let code = aadstsCode(in: text)
        if let code, interactionCodes.contains(code) {
            return .interactionRequired(code: code, message: text)
        }
        if lower.contains("interaction_required") {
            return .interactionRequired(code: code, message: text)
        }
        if lower.contains("az login") || lower.contains("please run 'az login'")
            || lower.contains("no subscription found") || lower.contains("refresh token has expired")
            || lower.contains("aadsts70043") || lower.contains("aadsts700082")
        {
            return .loginRequired(message: text)
        }
        return .commandFailed(exitCode: exitCode, stderr: text)
    }

    /// First `AADSTS<digits>` token in `text`.
    public static func aadstsCode(in text: String) -> String? {
        guard let r = text.range(of: #"AADSTS\d+"#, options: .regularExpression) else { return nil }
        return String(text[r])
    }
}
